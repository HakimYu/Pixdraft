import 'dart:async';
import 'dart:convert';
import 'dart:io';


import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/openai_client.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../api/support.dart';
import 'task_runner_test.dart' show KeyStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==');

  for (final protocol in [ApiProtocol.wavespeed, ApiProtocol.evolink]) {
    final wave = protocol == ApiProtocol.wavespeed;
    final provider = ProviderConfig(
      id: 'provider', name: '模拟供应商', baseUrl: 'https://provider.test',
      protocol: protocol, imageModel: wave ? 'sample/model' : 'doubao-seedream-5.5',
    );
    late StudioStore store;
    late Directory directory;
    Future<void> open() async {
      final opened = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
      store = KeyStore(opened.db, opened.root);
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('remote-recovery-');
      await open();
      await store.saveProvider(provider);
    });
    tearDown(() async {
      await store.close();
      await directory.delete(recursive: true);
    });

    Future<void> seed(String id, Map<String, Object?> metadata, {ProviderConfig? configuration}) async {
      await store.enqueue(GenerationInput(taskId: id, provider: configuration ?? provider,
        prompt: '猫', params: const GenerationParams(count: 3)));
      expect(await store.startAttempt(id), 1);
      await store.db.update('attempts', {'metadata': jsonEncode(metadata)},
        where: 'task_id = ?', whereArgs: [id]);
    }

    ResponseBody response(String status) {
      final task = {'status': status, if (status == 'completed')
        (wave ? 'outputs' : 'results'): ['https://cdn.test/out.png']};
      return jsonBody(wave ? {'data': task} : task);
    }

    TaskRunner runner(FakeAdapter adapter) {
      final client = OpenAiClient(readAsset: store.readAsset, assetLength: store.assetLength, dio: Dio()..httpClientAdapter = adapter);
      final media = FakeAdapter((_, _) async => ResponseBody.fromBytes(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/cetH5QAAAABJRU5ErkJggg=='), 200));
      return TaskRunner(store, client, recoveryClient: client, downloader: Dio()..httpClientAdapter = media);
    }

    test('${protocol.name} 重启只 GET 已记录 ID，保留已有位置和未知提交', () async {
      await seed('known', {'remote_checkpoints': {'0': 'first', '1': 'second'}});
      final first = await store.saveAsset(png, 'image/png');
      await store.attachOutput('known', first, 1, 0);
      await seed('unknown', {});
      await seed('legacy', {'remote_task_id': 'unbound'});
      await seed('cancelled', {'remote_checkpoints': {'0': 'cancelled'}});
      await store.transition('cancelled', TaskStatus.running, TaskStatus.aborted);
      await store.close();
      await open();
      await store.recoverInterrupted();

      final adapter = FakeAdapter((options, _) async {
        expect(options.method, 'GET');
        return response('completed');
      });
      await runner(adapter).drain();
      final tasks = {for (final task in await store.tasks()) task.id: task};
      expect(tasks['known']!.status, TaskStatus.partialError);
      expect(tasks['known']!.attempt, 1);
      expect(tasks['known']!.outputs, hasLength(2));
      expect(tasks['unknown']!.status, TaskStatus.interrupted);
      expect(tasks['legacy']!.status, TaskStatus.interrupted);
      expect(tasks['cancelled']!.status, TaskStatus.aborted);
      expect(adapter.requests.map((r) => r.uri.path), wave
        ? ['/api/v3/predictions/first/result', '/api/v3/predictions/second/result']
        : ['/v1/tasks/first', '/v1/tasks/second']);
      expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
    });

    test('${protocol.name} POST 返回 ID 后在轮询完成前持久化位置', () async {
      await store.enqueue(GenerationInput(taskId: 'live', provider: provider, prompt: '猫', params: const GenerationParams()));
      final requested = Completer<void>();
      final adapter = FakeAdapter((options, cancel) async {
        if (options.method == 'POST') {
          final task = {'id': 'accepted', 'status': 'processing'};
          return jsonBody(wave ? {'data': task} : task);
        }
        requested.complete();
        await cancel;
        return response('completed');
      });
      final active = runner(adapter);
      final draining = active.drain();
      await requested.future.timeout(const Duration(seconds: 5));
      expect(await store.remoteCheckpoints('live', 1), {0: 'accepted'});
      await active.cancel('live');
      await draining;
      expect(adapter.requests.map((r) => r.method), ['POST', 'GET']);
    });

    test('${protocol.name} 查询临时失败后继续原尝试，不重新提交', () async {
      await seed('resume', {'remote_checkpoints': {'0': 'remote'}});
      await store.recoverInterrupted();
      final transient = FakeAdapter((_, _) async => response('unknown'));
      await runner(transient).drain();
      expect((await store.task('resume'))!.status, TaskStatus.error);
      expect(await store.remoteCheckpoints('resume', 1), {0: 'remote'});
      await store.resumeRemoteTask('resume');
      final completed = FakeAdapter((_, _) async => response('completed'));
      await runner(completed).drain();
      final task = (await store.task('resume'))!;
      expect(task.attempt, 1);
      expect(task.outputs, hasLength(1));
      expect(completed.requests.map((r) => r.method), ['GET']);
      expect(await store.remoteCheckpoints('resume', 1), isEmpty);
    });

    test('${protocol.name} 远端明确失败后不可继续查询', () async {
      await seed('terminal', {'remote_checkpoints': {'0': 'remote'}});
      await store.recoverInterrupted();
      await runner(FakeAdapter((_, _) async => response('failed'))).drain();
      expect(await store.remoteCheckpoints('terminal', 1), isEmpty);
      await expectLater(store.resumeRemoteTask('terminal'), throwsStateError);
    });
    test('${protocol.name} 未知远端状态不重新提交', () async {
      await seed('unknown', {'remote_checkpoints': {'0': 'remote'}});
      await store.recoverInterrupted();
      final adapter = FakeAdapter((_, _) async => response('unknown'));
      await runner(adapter).drain();
      expect((await store.tasks()).single.error, contains('无法识别任务状态'));
      expect(adapter.requests.map((r) => r.method), ['GET']);
    });

    test('${protocol.name} 恢复查询取消后忽略迟到结果', () async {
      await seed('cancel', {'remote_checkpoints': {'0': 'remote'}});
      await store.recoverInterrupted();
      final requested = Completer<void>();
      final lateResponse = Completer<ResponseBody>();
      final adapter = FakeAdapter((_, _) {
        requested.complete();
        return lateResponse.future;
      });
      final active = runner(adapter);
      final draining = active.drain();
      await requested.future;
      await active.cancel('cancel');
      lateResponse.complete(response('completed'));
      await draining;
      final task = (await store.tasks()).single;
      expect(task.status, TaskStatus.aborted);
      expect(task.outputs, isEmpty);
      expect(adapter.requests.map((r) => r.method), ['GET']);
    });
  }
}
