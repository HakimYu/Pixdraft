import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/platform/background_tasks.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeForegroundTaskPlatform extends FlutterForegroundTaskPlatform {
  bool running = false;
  int startCount = 0;
  Object? startError;
  Function? entryCallback;
  NotificationIcon? startedWithIcon;
  int droppedMessages = 0;
  final List<Object> sentToTask = [];
  final List<ForegroundServiceTypes> requestedTypes = [];

  @override
  Future<bool> get isRunningService async => running;

  @override
  Future<void> startService({
    required AndroidNotificationOptions androidNotificationOptions,
    required IOSNotificationOptions iosNotificationOptions,
    required ForegroundTaskOptions foregroundTaskOptions,
    int? serviceId,
    List<ForegroundServiceTypes>? serviceTypes,
    required String notificationTitle,
    required String notificationText,
    NotificationIcon? notificationIcon,
    List<NotificationButton>? notificationButtons,
    String? notificationInitialRoute,
    Function? callback,
  }) async {
    startCount++;
    entryCallback = callback;
    startedWithIcon = notificationIcon;
    requestedTypes.addAll(serviceTypes ?? const []);
    if (startError != null) throw startError!;
    running = true;
  }

  @override
  void sendDataToTask(Object data) {
    sentToTask.add(data);
    if (droppedMessages > 0) { droppedMessages--; return; }
    if (data is Map && data['requestId'] != null) {
      FlutterForegroundTask.sendDataToMain({'ack': data['requestId']});
    }
  }

  @override
  Future<NotificationPermission> checkNotificationPermission() async =>
      NotificationPermission.granted;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      NotificationPermission.granted;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late _FakeForegroundTaskPlatform fake;
  late Directory directory;
  late StudioStore store;
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.com/v1');

  Future<void> enqueue(String taskId) => store.enqueue(
        GenerationInput(
          taskId: taskId,
          provider: provider,
          prompt: '猫',
          params: const GenerationParams(),
        ),
      );

  setUp(() async {
    fake = _FakeForegroundTaskPlatform();
    FlutterForegroundTaskPlatform.instance = fake;
    directory = await Directory.systemTemp.createTemp('image-gen-platform-test-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('桌面在进程内恢复和排空，不访问 Android 服务', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    fake.running = true;
    await enqueue('interrupted');
    await store.startAttempt('interrupted');
    await enqueue('queued');
    expect(await BackgroundTasks.recoverStaleTasks(store), isTrue);
    final drained = BackgroundTasks.changes.asyncMap((_) => store.tasks()).firstWhere(
      (tasks) => tasks.any((task) => task.id == 'queued' && task.status == TaskStatus.error),
    );
    await BackgroundTasks.resumeQueue(store);
    final tasks = await drained.timeout(const Duration(seconds: 5));
    expect(tasks.firstWhere((task) => task.id == 'interrupted').status, TaskStatus.interrupted);
    expect(fake.startCount, 0);
    expect(fake.sentToTask, isEmpty);
  });
  test('服务已在运行时 start 只发送排空命令', () async {
    fake.running = true;

    final result = await BackgroundTasks.start();

    expect(result.started, isTrue);
    expect(fake.startCount, 0);
    expect(fake.sentToTask.single, containsPair('command', BackgroundTasks.drainCommand));
    expect(fake.sentToTask.single, contains('requestId'));
  });

  test('服务未运行时以 dataSync 类型启动前台服务', () async {
    final result = await BackgroundTasks.start();

    expect(result.started, isTrue);
    expect(fake.startCount, 1);
    expect(fake.requestedTypes, [ForegroundServiceTypes.dataSync]);
    expect(fake.entryCallback, isNotNull);
    expect(fake.startedWithIcon?.metaDataName, 'com.dinosaur.imagegen.generation_running_icon');
    expect(
      fake.startedWithIcon?.toJson()['largeIconMetaDataName'],
      'com.dinosaur.imagegen.generation_running_large_icon',
    );
    expect(fake.sentToTask.single, containsPair('command', BackgroundTasks.drainCommand));
  });

  test('启动失败返回可解释状态且任务仍留在队列', () async {
    await enqueue('t1');
    fake.startError = PlatformException(code: 'boom', message: '启动失败');

    final result = await BackgroundTasks.start();

    expect(result.started, isFalse);
    expect(result.message, contains('后台服务启动失败'));
    expect((await store.tasks()).single.status, TaskStatus.queued);
  });

  test('cancel 只在服务运行时发送取消命令，并带上指定任务', () async {
    await BackgroundTasks.cancel();
    expect(fake.sentToTask, isEmpty);

    fake.running = true;
    await BackgroundTasks.cancel();
    await BackgroundTasks.cancel(taskId: 't9');
    expect(fake.sentToTask, [
      const {'command': BackgroundTasks.cancelCommand},
      const {'command': BackgroundTasks.cancelCommand, 'taskId': 't9'},
    ]);
  });

  test('服务仍在运行时不做中断恢复', () async {
    await enqueue('t1');
    await store.updateTask('t1', {'status': TaskStatus.running.name});
    fake.running = true;

    expect(await BackgroundTasks.recoverStaleTasks(store), isFalse);
    expect((await store.tasks()).single.status, TaskStatus.running);
  });

  test('服务已停止时把遗留 running 标为中断', () async {
    await enqueue('t1');
    await store.updateTask('t1', {'status': TaskStatus.running.name});

    expect(await BackgroundTasks.recoverStaleTasks(store), isTrue);
    expect((await store.tasks()).single.status, TaskStatus.interrupted);
  });
  test('通道未就绪丢失首次排空消息时等待确认并重发', () async {
    fake.running = true;
    fake.droppedMessages = 1;
    expect((await BackgroundTasks.start()).started, isTrue);
    expect(fake.sentToTask, hasLength(2));
    expect((fake.sentToTask[0] as Map)['requestId'], (fake.sentToTask[1] as Map)['requestId']);
  });

  test('服务不存在时取消能释放 running 状态且不改已完成任务', () async {
    await enqueue('t1');
    await store.updateTask('t1', {'status': 'running'});
    await BackgroundTasks.cancel(taskId: 't1', store: store);
    expect((await store.tasks()).single.status, TaskStatus.interrupted);
    await store.updateTask('t1', {'status': 'done'});
    await BackgroundTasks.cancel(taskId: 't1', store: store);
    expect((await store.tasks()).single.status, TaskStatus.done);
  });
}
