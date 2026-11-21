import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/flutter_foreground_task_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/platform/background_tasks.dart';
import 'package:image_gen/platform/background_worker.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Store extends StudioStore {
  _Store(super.db, super.root);
  Completer<String?>? keyGate;
  int keyReads = 0;
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async {
    keyReads++;
    return keyGate == null ? 'test-key' : await keyGate!.future;
  }
}

class _Client implements GenerationClient {
  final events = <String, StreamController<GenerationEvent>>{};
  final started = <String, Completer<void>>{};
  final calls = <String>[];
  final cancelled = <String>[];

  Future<void> waitFor(String id) => started.putIfAbsent(id, Completer<void>.new).future.timeout(const Duration(seconds: 5));
  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) {
    calls.add(input.taskId);
    final stream = events.putIfAbsent(input.taskId, StreamController<GenerationEvent>.new);
    started.putIfAbsent(input.taskId, Completer<void>.new).complete();
    return stream.stream;
  }
  @override
  void cancel(String taskId) => cancelled.add(taskId);
}

class _Downloads implements HttpClientAdapter {
  final responses = <String, Completer<ResponseBody>>{};
  final cancelled = <String>{};
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    final id = options.uri.pathSegments.last;
    cancelFuture?.then((_) => cancelled.add(id));
    return responses.putIfAbsent(id, Completer<ResponseBody>.new).future;
  }
  @override
  void close({bool force = false}) {}
}
class _Platform extends FlutterForegroundTaskPlatform {
  final titles = <String?>[];
  final buttons = <String>[];
  int stops = 0;
  bool running = true;
  @override
  Future<bool> get isRunningService async => running;
  @override
  Future<void> updateService({ForegroundTaskOptions? foregroundTaskOptions, String? notificationTitle, String? notificationText, NotificationIcon? notificationIcon, List<NotificationButton>? notificationButtons, String? notificationInitialRoute, Function? callback}) async {
    titles.add(notificationTitle);
    buttons.addAll(notificationButtons?.map((b) => b.text) ?? []);
  }
  @override
  Future<void> stopService() async { stops++; running = false; }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待任务状态超时');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late _Store store;
  late _Client client;
  late TaskRunner runner;
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.com/v1');
  final image = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
  Future<void> enqueue(String id) => store.enqueue(GenerationInput(taskId: id, provider: provider, prompt: id, params: const GenerationParams()));

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parallel-runner-');
    final opened = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    store = _Store(opened.db, opened.root);
    await store.saveProvider(provider);
    client = _Client();
    runner = TaskRunner(store, client);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('多任务同时启动，重复调度不重发，取消与迟到结果只影响指定任务', () async {
    await enqueue('a');
    await enqueue('b');
    final running = runner.drain();
    await Future.wait([client.waitFor('a'), client.waitFor('b')]);
    final repeated = runner.drain();
    expect(runner.activeTaskIds, {'a', 'b'});
    client.events['a']!.add(GenerationEvent('preview', bytes: image));
    client.events['b']!.add(GenerationEvent('preview', bytes: image));
    await _until(() => runner.previews.length == 2);
    await runner.cancel('a');
    expect(client.cancelled, ['a']);
    expect(runner.previews.keys, ['b']);
    client.events['a']!.add(GenerationEvent('image', bytes: image, key: 'late'));
    client.events['b']!.add(GenerationEvent('image', bytes: image, key: 'same-event-key'));
    await Future.wait(client.events.values.map((s) => s.close()));
    await Future.wait([running, repeated]);
    final tasks = {for (final t in await store.tasks()) t.id: t};
    expect(tasks['a']!.status, TaskStatus.aborted);
    expect(tasks['a']!.outputs, isEmpty);
    expect(tasks['b']!.status, TaskStatus.done);
    expect(tasks['b']!.outputs, hasLength(1));
    expect(client.calls, unorderedEquals(['a', 'b']));
    expect(runner.activeTaskIds, isEmpty);
    expect(runner.previews, isEmpty);
  });

  test('运行时新提交立即启动，一个失败不阻塞其它任务保存相同图片', () async {
    await enqueue('a');
    final first = runner.drain();
    await client.waitFor('a');
    await enqueue('b');
    await enqueue('c');
    final next = runner.drain();
    await Future.wait([client.waitFor('b'), client.waitFor('c')]);
    client.events['a']!.addError(const FormatException('供应商拒绝请求'));
    for (final id in ['b', 'c']) {
      client.events[id]!.add(GenerationEvent('image', bytes: image, key: 'same-event-key'));
    }
    await Future.wait(client.events.values.map((s) => s.close()));
    await Future.wait([first, next]);
    final tasks = {for (final t in await store.tasks()) t.id: t};
    expect(tasks['a']!.status, TaskStatus.error);
    expect(tasks['b']!.status, TaskStatus.done);
    expect(tasks['c']!.status, TaskStatus.done);
    expect(tasks['b']!.outputs.single.id, tasks['c']!.outputs.single.id);
    expect(await store.db.query('assets'), hasLength(1));
    expect(await store.db.query('attempts'), hasLength(3));
  });

  test('获取密钥期间取消不发起生成，之后显式重试不残留取消标记', () async {
    store.keyGate = Completer<String?>();
    await enqueue('a');
    final running = runner.drain();
    await _until(() => store.keyReads == 1);
    await runner.cancel('a');
    store.keyGate!.complete('test-key');
    await running;
    expect(client.calls, isEmpty);
    expect((await store.tasks()).single.status, TaskStatus.aborted);
    await store.retryTask('a');
    final retried = runner.drain();
    await client.waitFor('a');
    client.events['a']!.add(GenerationEvent('image', bytes: image));
    await client.events['a']!.close();
    await retried;
    expect((await store.tasks()).single.status, TaskStatus.done);
    expect(client.calls, ['a']);
  });

  test('同时下载时取消一项不取消其它下载，失败地址保留供单独恢复', () async {
    final downloads = _Downloads();
    final dio = Dio()..httpClientAdapter = downloads;
    runner = TaskRunner(store, client, downloader: dio);
    await enqueue('a');
    await enqueue('b');
    final running = runner.drain();
    await Future.wait([client.waitFor('a'), client.waitFor('b')]);
    for (final id in ['a', 'b']) {
      client.events[id]!.add(GenerationEvent('image', url: 'https://images.test/$id'));
    }
    await _until(() => downloads.responses.length == 2);
    await runner.cancel('a');
    await _until(() => downloads.cancelled.contains('a'));
    expect(downloads.cancelled, {'a'});
    for (final response in downloads.responses.values) {
      response.complete(ResponseBody(Stream.value(image), 200));
    }
    await Future.wait(client.events.values.map((s) => s.close()));
    await running;
    final tasks = {for (final t in await store.tasks()) t.id: t};
    expect(tasks['a']!.status, TaskStatus.aborted);
    expect(tasks['a']!.outputs, isEmpty);
    expect(tasks['b']!.status, TaskStatus.done);
    expect(tasks['b']!.outputs, hasLength(1));
    expect(await store.setting('pending:a:1:0'), isNotNull);
    expect(await store.setting('pending:b:1:0'), isNull);
    dio.close();
  });
  test('后台接收运行期间的新任务，通知计数变化且最后一个结束前不停服', () async {
    final platform = _Platform();
    FlutterForegroundTaskPlatform.instance = platform;
    final handler = BackgroundTaskHandler.forTesting(store, runner);
    await enqueue('a');
    final running = handler.onStart(DateTime.now(), TaskStarter.developer);
    await client.waitFor('a');
    await enqueue('b');
    handler.onReceiveData({'command': BackgroundTasks.drainCommand});
    await client.waitFor('b');
    expect(platform.titles, contains('正在生成 2 个任务'));
    client.events['a']!.add(GenerationEvent('image', bytes: image));
    await client.events['a']!.close();
    await _until(() => runner.activeTaskIds.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(platform.stops, 0);
    expect(platform.titles.last, '正在生成 1 个任务');
    client.events['b']!.add(GenerationEvent('image', bytes: image));
    await client.events['b']!.close();
    await running;
    await _until(() => platform.stops == 1);
    expect(platform.titles.last, '图片生成已结束');
    expect(platform.buttons, everyElement('取消全部任务'));
    await handler.onDestroy(DateTime.now(), false);
  });

  test('后台卡片取消只影响指定任务，通知按钮取消所有剩余任务', () async {
    final platform = _Platform();
    FlutterForegroundTaskPlatform.instance = platform;
    final handler = BackgroundTaskHandler.forTesting(store, runner);
    await enqueue('a');
    await enqueue('b');
    final running = handler.onStart(DateTime.now(), TaskStarter.developer);
    await Future.wait([client.waitFor('a'), client.waitFor('b')]);
    handler.onReceiveData({'command': BackgroundTasks.cancelCommand, 'taskId': 'a'});
    await _until(() => client.cancelled.contains('a'));
    expect(client.cancelled, ['a']);
    handler.onNotificationButtonPressed(BackgroundTasks.cancelButtonId);
    await _until(() => client.cancelled.contains('b'));
    await Future.wait(client.events.values.map((s) => s.close()));
    await running;
    expect((await store.tasks()).map((t) => t.status), everyElement(TaskStatus.aborted));
    await handler.onDestroy(DateTime.now(), false);
  });

  test('排空后只按本次完成的任务发出完成提醒', () async {
    FlutterForegroundTaskPlatform.instance = _Platform();
    final notes = <String>[];
    final handler = BackgroundTaskHandler.forTesting(store, runner, finished: (done, failed) async => notes.add('$done/$failed'));
    await enqueue('a');
    await enqueue('b');
    final running = handler.onStart(DateTime.now(), TaskStarter.developer);
    await Future.wait([client.waitFor('a'), client.waitFor('b')]);
    client.events['a']!.add(GenerationEvent('image', bytes: image));
    client.events['b']!.addError(const FormatException('供应商拒绝请求'));
    await Future.wait(client.events.values.map((s) => s.close()));
    await running;
    await _until(() => notes.isNotEmpty);
    expect(notes, ['1/1']);
    await handler.onDestroy(DateTime.now(), false);
  });
}
