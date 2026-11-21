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
import 'package:image_gen/platform/background_worker.dart';
import 'package:image_gen/tasks/recover_downloads.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Store extends StudioStore {
  _Store(super.db, super.root);
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => 'test-key';
}

class _Client implements GenerationClient {
  final events = StreamController<GenerationEvent>();
  final started = Completer<void>();
  int calls = 0;
  @override
  Stream<GenerationEvent> generate(GenerationInput input, String key) {
    calls++;
    started.complete();
    return events.stream;
  }
  @override
  void cancel(String id) {}
}

class _Downloads implements HttpClientAdapter {
  _Downloads(this.image);
  final Uint8List image;
  final requested = <String>[];
  bool fail = true;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? body, Future<void>? cancel) async {
    requested.add(options.uri.path);
    return fail && options.uri.path != '/three'
        ? ResponseBody.fromString('failed', 500)
        : ResponseBody(Stream.value(image), 200);
  }
  @override
  void close({bool force = false}) {}
}

class _Platform extends FlutterForegroundTaskPlatform {
  int stops = 0;
  @override
  Future<bool> get isRunningService async => true;
  @override
  Future<void> stopService() async { stops++; }
  @override
  Future<void> updateService({ForegroundTaskOptions? foregroundTaskOptions, String? notificationTitle, String? notificationText, NotificationIcon? notificationIcon, List<NotificationButton>? notificationButtons, String? notificationInitialRoute, Function? callback}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.test/v1');
  final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
  Uint8List svg(String color) => Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="$color"/></svg>'));
  late Directory directory;
  late _Store store;
  late _Client client;
  late TaskRunner runner;
  late _Platform platform;
  late FlutterForegroundTaskPlatform originalPlatform;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('task-regressions-');
    final opened = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    store = _Store(opened.db, opened.root);
    await store.saveProvider(provider);
    client = _Client();
    runner = TaskRunner(store, client);
    originalPlatform = FlutterForegroundTaskPlatform.instance;
    platform = _Platform();
    FlutterForegroundTaskPlatform.instance = platform;
  });
  tearDown(() async {
    FlutterForegroundTaskPlatform.instance = originalPlatform;
    await store.close();
    await directory.delete(recursive: true);
  });
  Future<void> enqueue({int count = 1}) => store.enqueue(GenerationInput(taskId: 't', provider: provider, prompt: '测试', params: GenerationParams(count: count)));

  test('进程重启后隔离未知和已知远端请求，保留原图且不重新生成', () async {
    await enqueue();
    await store.startAttempt('t');
    final asset = await store.saveAsset(png, 'image/png');
    await store.attachOutput('t', asset, 1, 0, requireRunning: true);
    await store.db.update('attempts', {
      'metadata': jsonEncode({'remote_task_id': 'remote-123'}),
    });
    await store.enqueue(GenerationInput(taskId: 'unknown', provider: provider,
      prompt: '测试', params: const GenerationParams()));
    await store.startAttempt('unknown');
    await store.close();

    final reopened = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    store = _Store(reopened.db, reopened.root);
    await store.recoverInterrupted();
    await TaskRunner(store, client).drain();
    final tasks = {for (final task in await store.tasks()) task.id: task};
    expect(tasks.values.map((task) => task.status), everyElement(TaskStatus.interrupted));
    expect(tasks['t']!.outputs.single.id, asset.id);
    expect(tasks['unknown']!.outputs, isEmpty);
    expect(client.calls, 0);
  });

  test('取消后的迟到预览和结果不会重新显示或落库', () async {
    await enqueue();
    final running = runner.drain();
    await client.started.future;
    await runner.cancel('t');
    client.events.add(GenerationEvent('preview', bytes: png));
    client.events.add(GenerationEvent('image', bytes: png));
    await client.events.close();
    await running;
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.aborted);
    expect(task.outputs, isEmpty);
    expect(runner.previews, isEmpty);
    expect(client.calls, 1);
  });
  test('连续下载失败不覆盖地址，后续结果仍保存，恢复只发 GET', () async {
    await enqueue(count: 3);
    final downloads = _Downloads(png);
    final dio = Dio()..httpClientAdapter = downloads;
    addTearDown(dio.close);
    runner = TaskRunner(store, client, downloader: dio);
    final running = runner.drain();
    await client.started.future;
    for (final path in ['one', 'two', 'three']) {
      client.events.add(GenerationEvent('image', url: 'https://cdn.test/$path'));
    }
    await client.events.close();
    await running;
    expect(downloads.requested, ['/one', '/two', '/three']);
    expect((await store.tasks()).single.status, TaskStatus.partialError);
    expect((await store.tasks()).single.outputs, hasLength(1));
    final pending = await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%'], orderBy: 'key');
    expect(pending.map((row) => row['key']), ['pending:t:1:0', 'pending:t:1:1']);
    expect(pending.map((row) => (jsonDecode(row['value'] as String) as Map)['url']), ['https://cdn.test/one', 'https://cdn.test/two']);
    downloads.fail = false;
    expect(await retrySavedDownloads(store, 't', downloader: dio), 2);
    expect(await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%']), isEmpty);
    expect(client.calls, 1);
  });

  test('执行记录插入失败回滚状态和次数，不发 API，下次调度可恢复', () async {
    await enqueue();
    await store.db.execute("CREATE TRIGGER fail_attempt BEFORE INSERT ON attempts BEGIN SELECT RAISE(ABORT, 'attempt write failed'); END");
    await expectLater(runner.drain(), throwsA(isA<DatabaseException>()));
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.queued);
    expect(task.attempt, 0);
    expect(runner.activeTaskIds, isEmpty);
    expect(client.calls, 0);
    expect(await store.db.query('attempts'), isEmpty);
    await store.db.execute('DROP TRIGGER fail_attempt');
    final running = runner.drain();
    await client.started.future;
    client.events.add(GenerationEvent('image', bytes: png));
    await client.events.close();
    await running;
    expect((await store.tasks()).single.status, TaskStatus.done);
  });

  test('同一任务保存多图，完成摘要按图片数量统计', () async {
    await enqueue(count: 2);
    final notes = <(int, int)>[];
    final handler = BackgroundTaskHandler.forTesting(store, runner, finished: (done, failed) async { notes.add((done, failed)); });
    final running = handler.onStart(DateTime.now(), TaskStarter.developer);
    await client.started.future;
    for (final color in ['red', 'blue']) {
      client.events.add(GenerationEvent('image', bytes: svg(color), mime: 'image/svg+xml', key: color));
    }
    await client.events.close();
    await running;
    expect(notes, [(2, 0)]);
    expect(platform.stops, 1);
    await handler.onDestroy(DateTime.now(), false);
  });

  test('本轮重试旧失败任务会提醒，部分失败保存的图片也计入', () async {
    await enqueue(count: 2);
    await store.updateTask('t', {'status': 'error'});
    final notes = <(int, int)>[];
    final handler = BackgroundTaskHandler.forTesting(store, runner, finished: (done, failed) async { notes.add((done, failed)); });
    final starting = handler.onStart(DateTime.now(), TaskStarter.developer);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await store.retryTask('t');
    handler.onReceiveData({'command': 'drain'});
    await client.started.future;
    client.events.add(GenerationEvent('image', bytes: png));
    await client.events.close();
    await starting;
    for (var i = 0; i < 400 && platform.stops == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(notes, [(1, 1)]);
    expect(platform.stops, 1);
    await handler.onDestroy(DateTime.now(), false);
  });
}
