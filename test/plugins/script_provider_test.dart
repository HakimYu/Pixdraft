import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/script_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'jsf_support.dart';

/// 记录宿主实际发出的请求；测试不碰真实网络。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body, {Map<String, List<String>>? headers}) =>
    ResponseBody.fromBytes(utf8.encode(body as String), status, headers: {
      'content-type': ['application/json'],
      ...?headers,
    });

PluginManifest _manifest({List<String> credentials = const ['api.example.com']}) =>
    PluginManifest.fromJson({
      'id': 'com.example.script',
      'name': '脚本供应商',
      'version': '1.0.0',
      'apiVersion': 1,
      'entry': 'index.js',
      'permissions': {'credentials': credentials, 'image': true},
      'providers': [
        {'id': 'acme.images', 'name': 'Acme 生图', 'plan': 'plan', 'interpret': 'interpret'},
      ],
      'processors': <Map<String, dynamic>>[],
      'tools': <Map<String, dynamic>>[],
    });

String _script({String url = 'https://api.example.com/v1/images', String? headers}) => '''
function plan(payload) {
  return {
    url: '$url',
    method: 'POST',
    headers: ${headers ?? '{}'},
    body: {prompt: payload.prompt}
  };
}
function interpret(response) { return {images: []}; }
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final skip = jsfAvailable() ? null : jsfSkipReason;
  late Directory directory;
  late StudioStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('script-provider-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  GenerationInput input({
    String taskId = 'task-script',
    bool allowHttp = false,
    String baseUrl = 'https://api.example.com',
  }) => GenerationInput(
    taskId: taskId,
    provider: ProviderConfig(
      id: 'acme',
      name: 'Acme',
      baseUrl: baseUrl,
      adapterId: 'acme.images',
      allowHttp: allowHttp,
    ),
    prompt: '一只猫',
    params: const GenerationParams(),
  );

  ({ScriptProviderExtension extension, _FakeAdapter adapter}) build(
    String source, {
    List<String> credentials = const ['api.example.com'],
    ResponseBody Function(RequestOptions)? handler,
  }) {
    final manifest = _manifest(credentials: credentials);
    final adapter = _FakeAdapter(
      handler ?? (_) => _json(200, '{"data": []}'),
    );
    final extension = ScriptProviderExtension(
      descriptor: manifest.providers.single.descriptor(
        manifest.id,
        manifest.version,
      ),
      spec: manifest.providers.single,
      manifest: manifest,
      source: source,
      store: store,
      client: Dio()..httpClientAdapter = adapter,
    );
    return (extension: extension, adapter: adapter);
  }

  Future<({List<GenerationEvent> events, Object? error})> collect(
    ScriptProviderExtension extension,
    GenerationInput generation,
  ) async {
    final events = <GenerationEvent>[];
    Object? error;
    try {
      await for (final event in extension.generate(generation, 'sk-test')) {
        events.add(event);
      }
    } on Object catch (thrown) {
      error = thrown;
    }
    return (events: events, error: error);
  }

  test('授权域名：宿主注入凭据，脚本拿不到 key', () async {
    final provider = build(_script());
    final result = await collect(provider.extension, input());

    expect(result.error, isNull);
    expect(result.events.last.kind, 'done');
    final request = provider.adapter.requests.single;
    expect(request.headers['authorization'], 'Bearer sk-test');
    expect(request.uri.host, 'api.example.com');
  }, skip: skip);

  test('未授权域名：直接拒绝，一次请求都不发', () async {
    final provider = build(_script(url: 'https://evil.example.org/v1'));
    final result = await collect(provider.extension, input());

    expect(result.error, isA<PluginException>());
    expect('${result.error}', contains('拒绝请求未授权域名：evil.example.org'));
    expect(provider.adapter.requests, isEmpty);
  }, skip: skip);

  test('重定向到未授权域名：第二跳被拒，不会带着凭据跟过去', () async {
    final provider = build(
      _script(),
      handler: (_) => _json(
        302,
        '{}',
        headers: {
          'location': ['https://evil.example.org/steal'],
        },
      ),
    );
    final result = await collect(provider.extension, input());

    expect(result.error, isA<PluginException>());
    expect('${result.error}', contains('拒绝重定向到未授权域名：evil.example.org'));
    expect(provider.adapter.requests.single.uri.host, 'api.example.com');
  }, skip: skip);

  test('脚本不能自己设置 Authorization，也不会替它发请求', () async {
    final provider = build(
      _script(headers: "{'Authorization': 'Bearer sk-leak'}"),
    );
    final result = await collect(provider.extension, input());

    expect(result.error, isA<PluginException>());
    expect('${result.error}', contains('保留头由宿主注入'));
    expect(provider.adapter.requests, isEmpty);
  }, skip: skip);

  test('HTTP 只有 allowHttp 打开后才放行', () async {
    final blocked = build(_script(url: 'http://api.example.com/v1'));
    final rejected = await collect(blocked.extension, input());
    expect(rejected.error, isA<PluginException>());
    expect('${rejected.error}', contains('拒绝请求未授权域名'));
    expect(blocked.adapter.requests, isEmpty);

    final allowed = build(_script(url: 'http://api.example.com/v1'));
    final passed = await collect(
      allowed.extension,
      input(allowHttp: true, baseUrl: 'http://api.example.com'),
    );
    expect(passed.error, isNull);
    expect(allowed.adapter.requests.single.uri.scheme, 'http');
  }, skip: skip);

  test('图片下载只接受 HTTPS 公网主机', () async {
    final provider = build('''
function plan(payload) { return {url: 'https://api.example.com/v1', method: 'POST'}; }
function interpret(response) { return {images: ['http://api.example.com/a.png']}; }
''');
    final result = await collect(provider.extension, input());

    expect(result.error, isA<PluginException>());
    expect('${result.error}', contains('图片地址不受理'));
  }, skip: skip);
}