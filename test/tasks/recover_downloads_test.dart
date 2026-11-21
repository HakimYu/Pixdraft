import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/tasks/recover_downloads.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.com/v1');
  const url = 'https://images.example.test/result.png';
  late Directory directory;
  late StudioStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('recover-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> seed({TaskStatus status = TaskStatus.partialError}) async {
    await store.enqueue(const GenerationInput(taskId: 't', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('t', {'status': status.name});
    await store.saveSetting('pending:t:0:0', {'url': url, 'mime': 'image/png', 'taskId': 't', 'attempt': 0, 'position': 0});
  }

  Dio dioReturningPng(RecordingAdapter adapter) => Dio()..httpClientAdapter = adapter;

  test('只 GET 已保存的地址、不带凭据，成功后清理 pending 并落盘', () async {
    await seed();
    final adapter = RecordingAdapter((_) async => ResponseBody(Stream.value(png), 200, headers: {Headers.contentTypeHeader: ['image/png']}));
    final recovered = await retrySavedDownloads(store, 't', downloader: dioReturningPng(adapter));
    expect(recovered, 1);
    final request = adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.uri.toString(), url);
    expect(request.headers.entries.where((e) => e.key.toLowerCase() == 'authorization' && e.value != null && '${e.value}'.trim().isNotEmpty), isEmpty);

    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.done);
    expect(task.outputs, hasLength(1));
    expect(await store.fileFor(task.outputs.single).readAsBytes(), png);
    expect(task.outputs.single.remoteUrl, url);
    expect(await store.db.query('task_assets', where: 'role = ?', whereArgs: ['output']), hasLength(1));
    expect(await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%']), isEmpty);
    expect(await store.db.query('tasks'), hasLength(1));
  });

  test('运行中的任务不允许恢复，pending 保留且不发请求', () async {
    await seed(status: TaskStatus.running);
    final adapter = RecordingAdapter((_) async => ResponseBody(Stream.value(png), 200));
    await expectLater(
      retrySavedDownloads(store, 't', downloader: dioReturningPng(adapter)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('请先停止'))),
    );
    expect(adapter.requests, isEmpty);
    expect(await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%']), hasLength(1));
    expect((await store.tasks()).single.status, TaskStatus.running);
  });

  test('下载失败时 pending 保留且不写入结果', () async {
    await seed();
    final adapter = RecordingAdapter((_) async => ResponseBody(Stream.value(Uint8List(0)), 500));
    await expectLater(retrySavedDownloads(store, 't', downloader: dioReturningPng(adapter)), throwsA(isA<DioException>()));
    expect((await store.tasks()).single.outputs, isEmpty);
    expect(await store.db.query('assets'), isEmpty);
    expect(await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%']), hasLength(1));
  });
  test('补回旧尝试图片时不覆盖新尝试的任务状态', () async {
    await seed();
    await store.updateTask('t', {'attempt': 1, 'status': 'error', 'error': '新尝试失败'});
    final adapter = RecordingAdapter((_) async => ResponseBody(Stream.value(png), 200));
    expect(await retrySavedDownloads(store, 't', downloader: dioReturningPng(adapter)), 1);
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.error);
    expect(task.error, '新尝试失败');
    expect(task.outputs, hasLength(1));
  });
}
