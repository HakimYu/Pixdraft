import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class KeyStore extends StudioStore {
  KeyStore(super.db, super.root);
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => 'private-test-key';
}

class FakeClient implements GenerationClient {
  final events = StreamController<GenerationEvent>();
  int calls = 0;
  final started = Completer<void>();
  @override
  Stream<GenerationEvent> generate(GenerationInput input, String key) {
    calls++;
    if (!started.isCompleted) started.complete();
    return events.stream;
  }
  @override
  void cancel(String taskId) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  late FakeClient client;
  late TaskRunner runner;
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.com/v1');
  final image = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runner-');
    final opened = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    store = KeyStore(opened.db, opened.root);
    await store.saveProvider(provider);
    client = FakeClient();
    runner = TaskRunner(store, client);
    await store.enqueue(const GenerationInput(taskId: 't', provider: provider, prompt: '猫', params: GenerationParams(count: 2)));
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('部分结果后断流保留图片且不自动重复请求', () async {
    final running = runner.drain();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    client.events.addError(const SocketException('断线，private-test-key'));
    await client.events.close();
    await running;
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.partialError);
    expect(task.outputs, hasLength(1));
    expect(task.error, isNot(contains('private-test-key')));
    expect(client.calls, 1);
  });

  test('取消后迟到图片不能恢复完成状态', () async {
    final running = runner.drain();
    await client.started.future;
    await runner.cancel('t');
    client.events.add(GenerationEvent('image', bytes: image, key: 'late'));
    await client.events.close();
    await running;
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.aborted);
    expect(task.outputs, isEmpty);
    expect(client.calls, 1);
  });

  test('重复终图按事件标识去重', () async {
    final running = runner.drain();
    client.events.add(GenerationEvent('image', bytes: image, key: 'same'));
    client.events.add(GenerationEvent('image', bytes: image, key: 'same'));
    await client.events.close();
    await running;
    expect((await store.tasks()).single.outputs, hasLength(1));
  });
  test('供应商地址改变后不向历史地址发送当前密钥', () async {
    await store.saveProvider(const ProviderConfig(id: 'p', name: '新服务', baseUrl: 'https://new.example.test/v1'), key: 'new-test-key');
    await runner.drain();
    expect(client.calls, 0);
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.error);
    expect(task.error, contains('供应商地址已变更'));
    client.events.stream.listen((_) {});
    await client.events.close();
  });

  test('SVG 单张规范化后不会误报部分失败', () async {
    await store.db.update('tasks', {'input': jsonEncode(const GenerationInput(taskId: 't', provider: provider, prompt: '猫', params: GenerationParams(count: 2, format: 'svg')).toJson())}, where: 'id = ?', whereArgs: ['t']);
    final running = runner.drain();
    client.events.add(GenerationEvent('image', bytes: Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>')), mime: 'image/svg+xml', key: 'svg'));
    await client.events.close();
    await running;
    expect((await store.tasks()).single.status, TaskStatus.done);
  });
}
