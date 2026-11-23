import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/providers/provider_connection.dart';
import 'package:image_gen/models/models.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.statusCode, this.body);

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ProviderConfig _provider({
  String baseUrl = 'https://api.example.com/openai/v1',
}) {
  return ProviderConfig(id: 'p1', name: '示例', baseUrl: baseUrl);
}

void main() {
  test('modelsUri 保留自定义前缀，空路径补 /v1，末尾斜杠归一化', () {
    expect(
      modelsUri('https://host/openai/v1/'),
      Uri.parse('https://host/openai/v1/models'),
    );
    expect(
      modelsUri('https://host/openai/v1'),
      Uri.parse('https://host/openai/v1/models'),
    );
    expect(modelsUri('https://host'), Uri.parse('https://host/v1/models'));
    expect(modelsUri('https://host/'), Uri.parse('https://host/v1/models'));
    expect(modelsUri('ftp://host/v1'), isNull);
    expect(modelsUri('not a url'), isNull);
  });

  test('200 返回模型列表，携带 Bearer 密钥，路径保留前缀', () async {
    final adapter = _RecordingAdapter(
      200,
      jsonEncode({
        'data': [
          {'id': 'a'},
          {'id': 'b'},
        ],
      }),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final checker = ProviderModelChecker(dio: dio);

    final result = await checker.check(_provider(), ' sk-key ');

    expect(result.status, ModelCheckStatus.ok);
    expect(result.models, ['a', 'b']);
    expect(result.message, contains('2 个模型'));
    expect(result.message, contains('未发起生图请求'));
    expect(adapter.lastRequest!.uri.path, '/openai/v1/models');
    expect(adapter.lastRequest!.headers['Authorization'], 'Bearer sk-key');
    expect(adapter.lastRequest!.followRedirects, isFalse);
  });

  test('WaveSpeed 目录提取图片端点规则，排除视频与其他端点', () async {
    const model = 'example/image-edit';
    const schema = {
      'properties': {
        'prompt': {'type': 'string'},
        'images': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 3},
      },
      'required': ['prompt', 'images'],
    };
    final adapter = _RecordingAdapter(200, jsonEncode({'data': [
      {'model_id': 'example/video', 'type': 'image-to-video'},
      {'model_id': model, 'type': 'image-to-image', 'api_schema': {'api_schemas': [
        {'type': 'model_run', 'method': 'POST', 'api_path': '/api/v3/other/model', 'request_schema': {}},
        {'type': 'model_run', 'method': 'POST', 'api_path': '/api/v3/$model', 'request_schema': schema},
      ]}},
    ]}));
    final dio = Dio()..httpClientAdapter = adapter;
    final result = await ProviderModelChecker(dio: dio).check(const ProviderConfig(
      id: 'wave', name: 'WaveSpeed', baseUrl: 'https://api.wavespeed.ai', protocol: ApiProtocol.wavespeed,
    ), 'test');
    expect(result.models, [model]);
    expect(result.imageSchemas, {model: schema});
    expect(adapter.lastRequest!.uri.path, '/api/v3/models');
  });
  test('无密钥时不发送 Authorization', () async {
    final adapter = _RecordingAdapter(200, jsonEncode({'data': []}));
    final dio = Dio()..httpClientAdapter = adapter;
    final checker = ProviderModelChecker(dio: dio);

    final result = await checker.check(_provider(), null);

    expect(result.status, ModelCheckStatus.ok);
    expect(adapter.lastRequest!.headers.containsKey('Authorization'), isFalse);
    expect(result.message, contains('未返回模型'));
  });

  test('404 说明缺少 /models 且不宣称生图不可用', () async {
    final adapter = _RecordingAdapter(404, 'not found');
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProviderModelChecker(dio: dio).check(_provider(), 'k');

    expect(result.status, ModelCheckStatus.noModelEndpoint);
    expect(result.message, contains('/models'));
    expect(result.message, contains('这不代表生图不可用'));
  });

  test('401 提示密钥无效', () async {
    final adapter = _RecordingAdapter(401, '');
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProviderModelChecker(dio: dio)
        .check(_provider(), 'bad');

    expect(result.status, ModelCheckStatus.unauthorized);
    expect(result.message, contains('密钥无效'));
  });

  test('重定向不跟随，避免凭据泄露', () async {
    final adapter = _RecordingAdapter(302, '');
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProviderModelChecker(dio: dio).check(_provider(), 'k');

    expect(result.status, ModelCheckStatus.redirected);
    expect(result.message, contains('重定向'));
    expect(adapter.lastRequest!.followRedirects, isFalse);
  });

  test('200 但结构不可识别时只说明检查结果', () async {
    final adapter = _RecordingAdapter(200, jsonEncode({'models': []}));
    final dio = Dio()..httpClientAdapter = adapter;

    final result = await ProviderModelChecker(dio: dio)
        .check(_provider(), null);

    expect(result.status, ModelCheckStatus.invalidResponse);
    expect(result.message, contains('这不代表生图不可用'));
  });
}
