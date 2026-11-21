import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/openai_client.dart';
import 'package:image_gen/models/models.dart';

import 'support.dart';

int indexOfBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

Future<T> withHttpServer<T>(
  Future<T> Function(HttpServer server, String baseUrl) run,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    return await run(server, 'http://127.0.0.1:${server.port}');
  } finally {
    await server.close(force: true);
  }
}

void main() {
  setUpAll(setUpApiFiles);
  tearDownAll(tearDownApiFiles);

  test('本地 HTTP Responses SSE：CRLF、UTF-8 跨字节与终图', () async {
    await withHttpServer((server, baseUrl) async {
      final requests = <String>[];
      final bodies = <String>[];
      final imageB64 = b64(samplePng);
      final sse = [
        'event: response.image_generation_call.partial_image',
        'data: {"type":"response.image_generation_call.partial_image","partial_image_b64":"$imageB64","output_format":"png"}',
        '',
        'event: response.output_item.done',
        'data: {"type":"response.output_item.done","item":{"type":"image_generation_call","id":"img_http","output_index":0,"status":"completed","result":"$imageB64","output_format":"png","revised_prompt":"一只猫"}}',
        '',
        'event: response.completed',
        'data: {"type":"response.completed","response":{"status":"completed","output":[]}}',
        '',
        '',
      ].join('\r\n');
      final bytes = utf8.encode(sse);
      final catAt = indexOfBytes(bytes, utf8.encode('猫'));
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.add(bytes.sublist(0, catAt + 1));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        request.response.add(bytes.sublist(catAt + 1, catAt + 2));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        request.response.add(bytes.sublist(catAt + 2));
        await request.response.close();
      });

      final client = OpenAiClient(readAsset: (asset) => fileFor(asset).readAsBytes(), assetLength: (asset) => fileFor(asset).length());
      final result = await drain(
        client.generate(
          testInput(
            provider: testProvider(
              baseUrl: baseUrl,
              allowHttp: true,
              protocol: ApiProtocol.responses,
              transport: TransportMode.stream,
            ),
            prompt: '一只猫',
          ),
          'key',
        ),
      );

      expect(result.error, isNull);
      expect(result.ofKind('image'), hasLength(1));
      expect(result.ofKind('image').single.bytes, samplePng);
      expect(result.ofKind('preview'), hasLength(1));
      expect(requests, ['POST /v1/responses']);
      final body = jsonDecode(bodies.single) as Map<String, dynamic>;
      expect(body['stream'], isTrue);
    });
  });

  test('本地 HTTP Images 编辑：JSON 400 后 multipart，保留自定义路径前缀', () async {
    await withHttpServer((server, baseUrl) async {
      final requests = <String>[];
      final contentTypes = <String>[];
      final bodies = <String>[];
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        contentTypes.add(request.headers.contentType?.mimeType ?? '');
        bodies.add(await utf8.decoder.bind(request).join());
        final wantsMultipart = contentTypes.last.contains('multipart');
        if (!wantsMultipart) {
          request.response.statusCode = 400;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'error': {'message': 'multipart/form-data required'},
          }));
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'data': [
              {'b64_json': b64(samplePng)},
            ],
          }));
        }
        await request.response.close();
      });

      final client = OpenAiClient(readAsset: (asset) => fileFor(asset).readAsBytes(), assetLength: (asset) => fileFor(asset).length());
      final result = await drain(
        client.generate(
          testInput(
            provider: testProvider(
              baseUrl: '$baseUrl/relay/custom',
              allowHttp: true,
              transport: TransportMode.json,
            ),
            prompt: '改成蓝色背景',
            params: const GenerationParams(count: 1),
            references: [referenceAsset()],
            mask: maskAsset(),
          ),
          'key',
        ),
      );

      expect(result.error, isNull);
      expect(result.ofKind('image'), hasLength(1));
      expect(requests, [
        'POST /relay/custom/images/edits',
        'POST /relay/custom/images/edits',
      ]);
      expect(contentTypes.first, contains('application/json'));
      expect(contentTypes.last, contains('multipart/form-data'));
      expect(bodies.last, contains('name="image[]"'));
      expect(bodies.last, contains('name="mask"'));
    });
  });
}
