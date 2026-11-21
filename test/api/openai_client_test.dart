import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/api_failure.dart';
import 'package:image_gen/models/models.dart';

import 'support.dart';

Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待条件超时');
}

void main() {
  setUpAll(setUpApiFiles);
  tearDownAll(tearDownApiFiles);

  test('Images 生成 JSON：参数、鉴权、事件与 metadata', () async {
    final adapter = FakeAdapter((options, cancelFuture) async {
      return jsonBody({
        'data': [
          {'b64_json': b64(samplePng)},
          {'b64_json': b64([9, 8, 7])},
        ],
      });
    });
    final client = clientFor(adapter);
    final provider = testProvider(transport: TransportMode.json);
    final result = await drain(
      client.generate(
        testInput(
          provider: provider,
          prompt: '一只猫',
          params: const GenerationParams(
            count: 2,
            size: '1000x1000',
            quality: 'high',
          ),
        ),
        'secret-key',
      ),
    );

    expect(result.error, isNull);
    expect(result.ofKind('started'), hasLength(1));
    final images = result.ofKind('image');
    expect(images, hasLength(2));
    expect(images[0].bytes, samplePng);
    expect(images[0].mime, 'image/png');
    expect(images[0].key, isNotEmpty);
    expect(images[0].key, isNot(images[1].key));
    expect(result.ofKind('done'), hasLength(1));

    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, '/v1/images/generations');
    expect(request.headers['Authorization'], 'Bearer secret-key');
    final body = request.data as Map<String, dynamic>;
    expect(body['model'], 'gpt-image-1');
    expect(body['prompt'], '一只猫');
    expect(body['n'], 2);
    expect(body['quality'], 'high');
    expect(body['output_format'], 'png');
    expect(body['background'], 'auto');
    expect(body['size'], isNot('1000x1000'));
    expect(body['size'].split('x').every((part) => int.parse(part) % 16 == 0), isTrue);
    expect(body['stream'], isNull);

    final metadata = result.ofKind('metadata').single;
    expect(metadata.metadata['protocol'], 'images');
    expect(metadata.metadata['transport'], 'json');
    expect(metadata.metadata['body'], 'json');
    expect(metadata.metadata['count'], 2);
    expect(metadata.metadata['delivered'], 2);
    expect(metadata.metadata['model'], 'gpt-image-1');
  });

  test('Images 编辑：JSON 被拒后回退 multipart，携带 image[] 与 mask', () async {
    var calls = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      calls++;
      if (calls == 1) {
        return errorBody(400, 'multipart/form-data required');
      }
      return jsonBody({
        'data': [
          {'b64_json': b64(samplePng)},
        ],
      });
    });
    final client = clientFor(adapter);
    final provider = testProvider(transport: TransportMode.json);
    final result = await drain(
      client.generate(
        testInput(
          provider: provider,
          prompt: '把背景换成蓝色',
          params: const GenerationParams(count: 1, inputFidelity: 'high'),
          references: [referenceAsset()],
          mask: maskAsset(),
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(result.ofKind('image'), hasLength(1));
    expect(adapter.requests, hasLength(2));

    final first = adapter.requests[0].data as Map<String, dynamic>;
    expect((first['images'] as List).single['image_url'], startsWith('data:image/png;base64,'));
    expect(first['mask'], isA<Map>());

    final second = adapter.requests[1].data;
    expect(second, isA<FormData>());
    final form = second as FormData;
    final fields = {for (final field in form.fields) field.key: field.value};
    expect(fields['model'], 'gpt-image-1');
    expect(fields['prompt'], '把背景换成蓝色');
    expect(fields['input_fidelity'], 'high');
    expect(form.files.map((file) => file.key), containsAll(['image[]', 'mask']));

    final metadata = result.ofKind('metadata').single.metadata;
    expect(metadata['body'], 'multipart');
  });

  test('Images SSE：partial 只发 preview，completed 发单张 image', () async {
    final imageB64 = b64(samplePng);
    final sse = [
      'event: image_generation.partial_image',
      'data: {"type":"image_generation.partial_image","partial_image_b64":"$imageB64","partial_image_index":0,"output_format":"png"}',
      '',
      'event: image_generation.completed',
      'data: {"type":"image_generation.completed","b64_json":"$imageB64","id":"img_sse","output_format":"png"}',
      '',
      '',
    ].join('\r\n');
    final adapter = FakeAdapter((options, cancelFuture) async => sseBody(sse));
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.stream),
          prompt: '一只猫',

        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(result.ofKind('preview'), hasLength(1));
    expect(result.ofKind('preview').single.bytes, samplePng);
    expect(result.ofKind('image'), hasLength(1));
    expect(result.ofKind('image').single.bytes, samplePng);
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['stream'], isTrue);
    expect(body['partial_images'], 1);
  });

  test('Responses SSE：preview 与终图去重，UTF-8 与 applied metadata', () async {
    final imageB64 = b64(samplePng);
    final sse = [
      'event: response.image_generation_call.partial_image',
      'data: {"type":"response.image_generation_call.partial_image","partial_image_b64":"$imageB64","partial_image_index":0,"output_format":"png"}',
      '',
      'event: response.output_item.done',
      'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","id":"img_1","output_index":0,"status":"completed","result":"$imageB64","output_format":"png","size":"1024x1024","quality":"high","revised_prompt":"一只猫"}}',
      '',
      'event: response.completed',
      'data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"image_generation_call","id":"img_1","output_index":0,"result":"$imageB64","output_format":"png"}]}}',
      '',
      '',
    ].join('\r\n');
    final adapter = FakeAdapter((options, cancelFuture) async => sseBody(sse));
    final client = clientFor(adapter);
    final provider = testProvider(
      protocol: ApiProtocol.responses,
      transport: TransportMode.stream,
    );
    final result = await drain(
      client.generate(
        testInput(
          provider: provider,
          prompt: '一只猫',
          params: const GenerationParams(quality: 'high'),
          references: [referenceAsset()],
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(result.ofKind('preview'), hasLength(1));
    expect(result.ofKind('preview').single.bytes, samplePng);
    expect(result.ofKind('image'), hasLength(1));
    expect(result.ofKind('image').single.bytes, samplePng);
    expect(result.ofKind('image').single.key, contains('img_1'));

    final request = adapter.requests.single;
    final body = request.data as Map<String, dynamic>;
    expect(body['model'], 'gpt-4.1');
    expect(body['stream'], isTrue);
    final tool = (body['tools'] as List).single as Map<String, dynamic>;
    expect(tool['type'], 'image_generation');
    expect(tool['model'], 'gpt-image-1');
    final content = (body['input'] as List).single['content'] as List;
    expect(content.first['type'], 'input_text');
    expect(content.first['text'], '一只猫');
    expect(content.last['type'], 'input_image');
    expect(content.last['image_url'], startsWith('data:image/png;base64,'));

    final metadata = result.ofKind('metadata').single.metadata;
    expect(metadata['protocol'], 'responses');
    expect(metadata['transport'], 'stream');
    expect(metadata['delivered'], 1);
    expect(metadata['applied'], containsPair('revisedPrompt', '一只猫'));
  });

  test('Responses 413：自动改用 file_id，并在结束前清理文件', () async {
    var responsesCalls = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      final path = options.uri.path;
      if (options.method == 'POST' && path == '/v1/files') {
        return jsonBody({'id': 'file_1'});
      }
      if (options.method == 'DELETE' && path == '/v1/files/file_1') {
        return jsonBody({});
      }
      if (path == '/v1/responses') {
        responsesCalls++;
        if (responsesCalls == 1) {
          return errorBody(413, 'payload too large');
        }
        return jsonBody({
          'output': [
            {
              'type': 'image_generation_call',
              'id': 'img_1',
              'output_index': 0,
              'result': b64(samplePng),
            },
          ],
        });
      }
      return errorBody(404, 'not found');
    });
    final client = clientFor(adapter);
    final provider = testProvider(
      protocol: ApiProtocol.responses,
      transport: TransportMode.json,
    );
    final result = await drain(
      client.generate(
        testInput(
          provider: provider,
          prompt: '重绘',
          references: [referenceAsset()],
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(result.ofKind('image'), hasLength(1));
    expect(adapter.requests.map((r) => '${r.method} ${r.uri.path}'), [
      'POST /v1/responses',
      'POST /v1/files',
      'POST /v1/responses',
      'DELETE /v1/files/file_1',
    ]);
    final retried = adapter.requests[2].data as Map<String, dynamic>;
    final content = (retried['input'] as List).single['content'] as List;
    expect(content.last['type'], 'input_image');
    expect(content.last['file_id'], 'file_1');
    expect(result.ofKind('metadata').single.metadata['file_input'], 'file_id');
  });

  test('fileInput=true：先上传再请求，结束后清理', () async {
    final adapter = FakeAdapter((options, cancelFuture) async {
      final path = options.uri.path;
      if (options.method == 'POST' && path == '/v1/files') {
        return jsonBody({'id': 'file_fixed'});
      }
      if (options.method == 'DELETE') {
        return jsonBody({});
      }
      if (path == '/v1/responses') {
        return jsonBody({
          'output': [
            {
              'type': 'image_generation_call',
              'id': 'img_1',
              'result': b64(samplePng),
            },
          ],
        });
      }
      return errorBody(404, 'not found');
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(
            protocol: ApiProtocol.responses,
            fileInput: true,
          ),
          prompt: '重绘',
          references: [referenceAsset()],
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(adapter.requests.map((r) => '${r.method} ${r.uri.path}'), [
      'POST /v1/files',
      'POST /v1/responses',
      'DELETE /v1/files/file_fixed',
    ]);
    final body = adapter.requests[1].data as Map<String, dynamic>;
    final content = (body['input'] as List).single['content'] as List;
    expect(content.last['file_id'], 'file_fixed');
  });

  test('已交付图片后断流：保留事件、报错且不重发', () async {
    final imageB64 = b64(samplePng);
    final firstEvent = [
      'event: response.output_item.done',
      'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","id":"img_1","result":"$imageB64","status":"completed"}}',
      '',
      '',
    ].join('\r\n');
    final adapter = FakeAdapter((options, cancelFuture) async {
      final controller = StreamController<Uint8List>();
      Future<void>(() async {
        controller.add(Uint8List.fromList(utf8.encode(firstEvent)));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        controller.addError(const SocketException('connection reset'));
        await controller.close();
      });
      return streamBody(controller.stream);
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(
            protocol: ApiProtocol.responses,
            transport: TransportMode.stream,
          ),
          prompt: '重绘',
          references: [referenceAsset()],
        ),
        'key',
      ),
    );

    expect(result.ofKind('image'), hasLength(1));
    expect(result.error, isA<FormatException>());
    expect(adapter.requests, hasLength(1));
  });

  for (final status in [401, 429, 500]) {
    test('HTTP $status 只请求一次且不降级重发', () async {
      final adapter = FakeAdapter((options, cancelFuture) async {
        return errorBody(status, 'upstream failure');
      });
      final client = clientFor(adapter);
      final result = await drain(
        client.generate(
          testInput(
            provider: testProvider(transport: TransportMode.auto),
            prompt: '一只猫',
          ),
          'key',
        ),
      );

      expect(result.ofKind('image'), isEmpty);
      expect(result.error, isA<ApiFailure>());
      expect((result.error as ApiFailure).status, status);
      expect(adapter.requests, hasLength(1));
    });
  }

  test('流式明确不支持：回退一次 JSON 并记录降级', () async {
    var calls = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      calls++;
      if (calls == 1) {
        return errorBody(400, 'streaming is not supported for this model');
      }
      return jsonBody({
        'data': [
          {'b64_json': b64(samplePng)},
        ],
      });
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.auto),
          prompt: '一只猫',
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(adapter.requests, hasLength(2));
    final metadata = result.ofKind('metadata').single.metadata;
    expect(metadata['transport'], 'json');
    expect(metadata['fallback_from_stream'], isTrue);
  });

  test('n 不支持：确认无图后拆成单图请求', () async {
    var calls = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      calls++;
      if (calls == 1) {
        return errorBody(400, 'unsupported parameter: n');
      }
      return jsonBody({
        'data': [
          {'b64_json': b64([calls])},
        ],
      });
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.json),
          prompt: '两只猫',
          params: const GenerationParams(count: 2),
        ),
        'key',
      ),
    );

    expect(result.error, isNull);
    expect(adapter.requests, hasLength(3));
    final images = result.ofKind('image');
    expect(images, hasLength(2));
    expect(images.map((image) => image.key).toSet(), hasLength(2));
    final metadata = result.ofKind('metadata').single.metadata;
    expect(metadata['split'], isTrue);
    expect(metadata['count'], 2);
    expect(metadata['delivered'], 2);
  });

  test('拆单图部分失败：保留已发图片、抛出错误并标记 partial', () async {
    var calls = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      calls++;
      if (calls == 1) {
        return errorBody(400, 'unsupported parameter: n');
      }
      if (calls == 2) {
        return jsonBody({
          'data': [
            {'b64_json': b64(samplePng)},
          ],
        });
      }
      return errorBody(500, 'upstream failure');
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.json),
          prompt: '两只猫',
          params: const GenerationParams(count: 2),
        ),
        'key',
      ),
    );

    expect(result.ofKind('image'), hasLength(1));
    expect(result.error, isA<ApiFailure>());
    expect((result.error as ApiFailure).status, 500);
    final partial = result.ofKind('metadata');
    expect(partial, hasLength(1));
    expect(partial.single.metadata['partial'], isTrue);
    expect(partial.single.metadata['delivered'], 1);
    expect(adapter.requests, hasLength(3));
  });

  test('markup 仅 Images 且与蒙版互斥', () async {
    var requests = 0;
    final adapter = FakeAdapter((options, cancelFuture) async {
      requests++;
      return jsonBody({
        'data': [
          {'b64_json': b64(samplePng)},
        ],
      });
    });
    final client = clientFor(adapter);

    final markupResult = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.json),
          prompt: '标注区域变红',
          references: [referenceAsset()],
          markup: maskAsset(),
        ),
        'key',
      ),
    );
    expect(markupResult.error, isNull);
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['markup'], isA<Map>());
    expect(body.containsKey('mask'), isFalse);

    final conflict = await drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.json),
          prompt: '冲突',
          references: [referenceAsset()],
          mask: maskAsset(),
          markup: maskAsset(),
        ),
        'key',
      ),
    );
    expect(conflict.error, isA<FormatException>());

    final responsesMarkup = await drain(
      client.generate(
        testInput(
          provider: testProvider(
            protocol: ApiProtocol.responses,
            transport: TransportMode.json,
          ),
          prompt: '标注',
          references: [referenceAsset()],
          markup: maskAsset(),
        ),
        'key',
      ),
    );
    expect(responsesMarkup.error, isA<FormatException>());
    expect(requests, 1);
  });

  test('取消：立即结束流且不产生错误事件', () async {
    final adapter = FakeAdapter((options, cancelFuture) async {
      await cancelFuture;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    });
    final client = clientFor(adapter);
    final pending = drain(
      client.generate(
        testInput(
          provider: testProvider(transport: TransportMode.json),
          prompt: '一只猫',
        ),
        'key',
      ),
    );

    await waitFor(() => adapter.requests.length == 1);
    client.cancel('task-1');
    final result = await pending.timeout(const Duration(seconds: 3));

    expect(result.error, isNull);
    expect(result.ofKind('image'), isEmpty);
    expect(result.ofKind('done'), isEmpty);
    expect(adapter.requests, hasLength(1));
  });

  test('900 秒总超时可由配置缩短，超时后不重发', () async {
    final adapter = FakeAdapter((options, cancelFuture) async {
      await cancelFuture;
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    });
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(
            transport: TransportMode.json,
            timeoutSeconds: 1,
          ),
          prompt: '一只猫',
        ),
        'key',
      ),
    );

    expect(result.error, isA<FormatException>());
    expect(result.error.toString(), contains('超时'));
    expect(adapter.requests, hasLength(1));
  });
}
