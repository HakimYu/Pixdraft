import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/params.dart';
import 'package:image_gen/models/models.dart';

import 'support.dart';

void main() {
  setUp(setUpApiFiles);
  tearDown(tearDownApiFiles);

  for (final protocol in [ApiProtocol.wavespeed, ApiProtocol.evolink]) {
    final wave = protocol == ApiProtocol.wavespeed;
    ProviderConfig provider({int timeout = 900}) => testProvider(
      baseUrl: wave ? 'https://api.wavespeed.ai' : 'https://api.evolink.ai',
      protocol: protocol,
      imageModel: wave ? 'bytedance/seedream-v5.5/edit' : 'doubao-seedream-5.5',
      timeoutSeconds: timeout,
    );
    Map<String, dynamic> task(String status, {String url = 'https://cdn.test/out.png'}) {
      final data = {'id': 'remote-123', 'status': status,
        if (status == 'completed') (wave ? 'outputs' : 'results'): [url],
        if (status == 'failed') 'error': {'message': '额度不足'},
      };
      return wave ? {'code': 200, 'data': data} : data;
    }

    test('${protocol.label} 上传参考图、提交一次并轮询保存结果', () async {
      final adapter = FakeAdapter((options, _) async {
        expect(options.headers['Authorization'], 'Bearer secret');
        if (options.uri.host == 'files-api.evolink.ai') {
          expect(options.path, 'https://files-api.evolink.ai/api/v1/files/upload/stream');
          expect(options.data, isA<FormData>());
          return jsonBody({'success': true, 'data': {'file_url': 'https://files.evolink.ai/ref.png'}});
        }
        if (options.method == 'POST') {
          final body = options.data as Map;
          expect(body['prompt'], '猫');
          expect(body['n'], isNull);
          expect(body[wave ? 'resolution' : 'quality'], wave ? '1.5k' : '1.5K');
          expect(body[wave ? 'aspect_ratio' : 'size'], '16:9');
          expect(body['output_format'], 'jpeg');
          expect(body[wave ? 'images' : 'image_urls'], wave
            ? ['data:image/png;base64,${base64Encode(samplePng)}']
            : ['https://files.evolink.ai/ref.png']);
          expect(options.uri.path, wave ? '/api/v3/bytedance/seedream-v5.5/edit' : '/v1/images/generations');
          return jsonBody(task('processing'));
        }
        expect(options.uri.path, wave ? '/api/v3/predictions/remote-123/result' : '/v1/tasks/remote-123');
        return jsonBody(task('completed'));
      });
      final result = await drain(clientFor(adapter).generate(testInput(
        provider: provider(), prompt: '猫', references: [referenceAsset()],
        params: const GenerationParams(size: '16:9', quality: '1.5K', format: 'jpeg'),
      ), 'secret'));
      expect(result.error, isNull);
      expect(result.ofKind('image').single.url, 'https://cdn.test/out.png');
      expect(result.ofKind('done'), hasLength(1));
      expect(result.ofKind('metadata').last.metadata['remote_task_ids'], ['remote-123']);
      expect(adapter.requests.where((r) => r.method == 'POST' && r.uri.host != 'files-api.evolink.ai'), hasLength(1));
      expect(result.ofKind('metadata').first.metadata['remote_task_id'], 'remote-123');
      expect(ProviderConfig.fromJson(provider().toJson()).protocol, protocol);
    });

    test('${protocol.label} 多张逐次提交，已完成结果保留且失败不重发', () async {
      var posts = 0;
      final adapter = FakeAdapter((options, _) async {
        if (options.uri.host == 'files-api.evolink.ai') {
          return jsonBody({'success': true, 'data': {'file_url': 'https://files.evolink.ai/ref.png'}});
        }
        posts++;
        return jsonBody(task(posts == 1 ? 'completed' : 'failed'));
      });
      final result = await drain(clientFor(adapter).generate(testInput(provider: provider(), prompt: '猫',
        references: [referenceAsset()], params: const GenerationParams(count: 3)), 'secret'));
      expect(result.error.toString(), contains('remote-123'));
      expect(result.ofKind('image'), hasLength(1));
      expect(posts, 2);
    });

    test('${protocol.label} 等待时取消立即退出，不再轮询或提交', () async {
      final submitted = Completer<void>();
      final adapter = FakeAdapter((options, _) async {
        if (options.uri.host == 'files-api.evolink.ai') {
          return jsonBody({'success': true, 'data': {'file_url': 'https://files.evolink.ai/ref.png'}});
        }
        submitted.complete();
        return jsonBody(task('processing'));
      });
      final client = clientFor(adapter);
      final future = drain(client.generate(testInput(provider: provider(), prompt: '猫', references: [referenceAsset()]), 'secret'));
      await submitted.future;
      client.cancel('task-1');
      final result = await future.timeout(const Duration(seconds: 1));
      expect(result.error, isNull);
      expect(adapter.requests.where((r) => r.method == 'GET'), isEmpty);
    });

    test('${protocol.label} 超时不重新提交', () async {
      final adapter = FakeAdapter((options, _) async {
        if (options.uri.host == 'files-api.evolink.ai') {
          return jsonBody({'success': true, 'data': {'file_url': 'https://files.evolink.ai/ref.png'}});
        }
        return jsonBody(task('processing'));
      });
      final result = await drain(clientFor(adapter).generate(testInput(provider: provider(timeout: 1), prompt: '猫', references: [referenceAsset()]), 'secret'));
      expect(result.error.toString(), contains('超时'));
      expect(adapter.requests.where((r) => r.method == 'GET'), isEmpty);
    });

    test('${protocol.label} 拒绝不支持的参数，提交前校验', () async {
      final adapter = FakeAdapter((_, _) async => throw StateError('不应发请求'));
      final result = await drain(clientFor(adapter).generate(testInput(provider: provider(), prompt: '猫',
        references: [referenceAsset()], params: const GenerationParams(format: 'webp')), 'secret'));
      expect(result.error.toString(), contains('PNG / JPEG'));
      expect(adapter.requests, isEmpty);
      expect(() => resolveParams(const GenerationParams(size: '9x9'), protocol: protocol,
        imageModel: provider().imageModel, hasInputImages: true), throwsFormatException);
    });
  }
}
