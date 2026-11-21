import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../data/studio_store.dart';
import '../models/models.dart';
import 'plugin_contract.dart';
import 'plugin_manifest.dart';
import 'plugin_runtime.dart';

/// 单次生成的往返上限：请求-解释循环最多 6 轮，图像最多 16 张。
const int scriptProviderMaxRounds = 6;
const int scriptProviderMaxImages = 16;
const int scriptProviderMaxResponseBytes = 32 * 1024 * 1024;
const int scriptProviderMaxReferenceBytes = 8 * 1024 * 1024;
const int scriptProviderMaxRedirects = 3;

/// 脚本供应商：脚本只描述请求与解释响应，网络由宿主在授权域名上执行。
class ScriptProviderExtension implements ProviderExtension {
  ScriptProviderExtension({
    required this.descriptor,
    required this.spec,
    required this.manifest,
    required this.source,
    required this.store,
    Dio? client,
  }) : _client = client ?? Dio();

  @override
  final ProviderDescriptor descriptor;
  final PluginProviderSpec spec;
  final PluginManifest manifest;

  /// 入口脚本源码；每次生成编译一次，避免共享运行时泄漏凭据。
  final String source;
  final StudioStore store;
  final Dio _client;
  final Map<String, _ScriptRun> _runs = {};

  @override
  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  }) => spec.capabilities;

  @override
  Future<GenerationPlan> plan(GenerationInput input) async {
    final count = input.params.count;
    if (count < 1 || count > scriptProviderMaxImages) {
      throw const PluginException('生成数量需为 1–16');
    }
    if (input.references.length > spec.capabilities.maxReferences) {
      throw PluginException('参考图最多 ${spec.capabilities.maxReferences} 张');
    }
    return GenerationPlan(
      input: input,
      expectedCount: count,
      metadata: {
        'adapterId': descriptor.id,
        'plugin': '${manifest.id}@${manifest.version}',
        'model': input.provider.imageModel,
      },
    );
  }

  @override
  Future<List<String>> discoverModels(
    ProviderConfig provider,
    String? apiKey,
  ) async => provider.imageModel.isEmpty ? const [] : [provider.imageModel];

  @override
  Stream<GenerationEvent> generate(
    GenerationInput input,
    String apiKey,
  ) async* {
    final taskId = input.taskId;
    final run = _ScriptRun();
    _runs[taskId] = run;
    PluginScript? script;
    try {
      script = PluginScript.compile(manifest: manifest, source: source);
      yield GenerationEvent('started', metadata: {'adapterId': descriptor.id});
      final request = _describeRequest(
        script.call(spec.planFunction, await _planPayload(input, run)),
      );
      var pending = request;
      for (var round = 0; round < scriptProviderMaxRounds; round++) {
        run.checkCancelled();
        final response = await _send(
          run,
          pending,
          apiKey,
          input.provider.allowHttp,
        );
        run.checkCancelled();
        final output = pluginScriptObject(
          script.call(spec.interpretFunction, response),
          spec.interpretFunction,
        );
        final error = output['error'];
        if (error != null) throw PluginException('供应商脚本报错：$error');
        final metadata = output['metadata'];
        if (metadata is Map) {
          yield GenerationEvent(
            'metadata',
            metadata: Map<String, dynamic>.from(metadata),
          );
        }
        final next = output['request'];
        if (next != null) {
          pending = _describeRequest(next);
          continue;
        }
        final raw = output['images'];
        if (raw == null) throw const PluginException('脚本未返回图片，也没有后续请求');
        if (raw is! List) throw const PluginException('脚本返回的 images 需为数组');
        for (final item in raw) {
          final url = item is Map ? item['url'] : item;
          if (url is! String || url.isEmpty) {
            throw const PluginException('图片需为 URL 字符串');
          }
          run.checkCancelled();
          final bytes = await _download(run, url);
          run.checkCancelled();
          yield GenerationEvent(
            'image',
            bytes: bytes,
            mime: item is Map && item['mime'] is String
                ? item['mime'] as String
                : 'image/png',
          );
        }
        break;
      }
      yield const GenerationEvent('done');
    } on ProcessingCancelled {
      // 取消不产生错误事件，与内置适配器一致。
    } catch (error) {
      if (!run.cancelled) {
        yield GenerationEvent('metadata', metadata: {'error': '$error'});
      }
      if (!run.cancelled) rethrow;
    } finally {
      _runs.remove(taskId);
      script?.dispose();
    }
  }

  @override
  void cancel(String taskId) {
    final run = _runs.remove(taskId);
    run?.cancel();
  }

  Future<Map<String, dynamic>> _planPayload(
    GenerationInput input,
    _ScriptRun run,
  ) async {
    final references = <Map<String, dynamic>>[];
    for (final reference in input.references) {
      run.checkCancelled();
      final bytes = await store.fileFor(reference).readAsBytes();
      if (bytes.length > scriptProviderMaxReferenceBytes) {
        throw PluginException(
          '参考图超过 ${scriptProviderMaxReferenceBytes ~/ (1024 * 1024)} MiB',
        );
      }
      references.add({
        'mime': reference.mime,
        'width': reference.width,
        'height': reference.height,
        'dataUrl': 'data:${reference.mime};base64,${base64Encode(bytes)}',
      });
    }
    final provider = input.provider;
    return {
      'taskId': input.taskId,
      'prompt': input.prompt,
      'count': input.params.count,
      'size': input.params.size,
      'quality': input.params.quality,
      'format': input.params.format,
      'references': references,
      'provider': {
        'baseUrl': provider.baseUrl,
        'model': provider.imageModel,
        'responseModel': provider.responseModel,
        'timeoutSeconds': provider.timeoutSeconds,
      },
      'config': provider.pluginConfig,
    };
  }

  Map<String, dynamic> _describeRequest(Object? value) {
    final json = pluginScriptObject(value, spec.planFunction);
    final url = json['url'];
    if (url is! String || url.isEmpty) {
      throw const PluginException('脚本请求需给出 url');
    }
    final method = json['method'];
    final headers = json['headers'];
    if (headers != null && headers is! Map) {
      throw const PluginException('请求 headers 需为对象');
    }
    if (headers is Map) {
      for (final key in headers.keys) {
        final name = key.toString().toLowerCase();
        if (name == 'authorization' ||
            name == 'cookie' ||
            name == 'host' ||
            name == 'content-length') {
          throw PluginException('保留头由宿主注入，脚本不得设置 $key');
        }
      }
    }
    final body = json['body'];
    return {
      'url': url,
      'method': method is String ? method.toUpperCase() : 'POST',
      'headers': headers == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(headers as Map),
      'body': body,
      'expect': json['expect'] == 'text' ? 'text' : 'json',
    };
  }

  /// 授权目标：HTTPS，或供应商显式允许的 HTTP；域名必须写在清单 credentials 里。
  /// 凭据只在这些目标上注入，其余地址一律拒绝请求。
  bool _authorized(Uri uri, bool allowHttp) {
    if (uri.scheme == 'https') {
      // 允许
    } else if (uri.scheme == 'http' && allowHttp) {
      // 供应商显式开启的不安全连接
    } else {
      return false;
    }
    return manifest.permissions.credentials.contains(uri.host.toLowerCase());
  }

  static void _checkDownloadable(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        RegExp(r'^[\d.]+$').hasMatch(uri.host) ||
        uri.host == 'localhost' ||
        uri.userInfo.isNotEmpty) {
      throw PluginException('图片地址不受理：$uri');
    }
  }

  Future<Map<String, dynamic>> _send(
    _ScriptRun run,
    Map<String, dynamic> request,
    String apiKey,
    bool allowHttp,
  ) async {
    var uri = Uri.tryParse(request['url'] as String);
    if (uri == null || uri.host.isEmpty) {
      throw const PluginException('脚本请求 URL 不合法');
    }
    final headers = Map<String, String>.from(
      (request['headers'] as Map).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );
    if (!_authorized(uri, allowHttp)) {
      throw PluginException('拒绝请求未授权域名：${uri.host}');
    }
    headers['authorization'] = 'Bearer $apiKey';
    final body = request['body'];
    for (var hop = 0; hop <= scriptProviderMaxRedirects; hop++) {
      run.checkCancelled();
      final response = await _client.request<List<int>>(
        uri.toString(),
        data: body,
        options: Options(
          method: request['method'] as String,
          headers: headers,
          followRedirects: false,
          validateStatus: (_) => true,
          responseType: ResponseType.bytes,
        ),
        cancelToken: run.cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = response.headers.value('location');
        if (location == null) {
          throw PluginException('重定向缺少 Location（HTTP $status）');
        }
        final next = uri!.resolve(location);
        if (!_authorized(next, allowHttp)) {
          throw PluginException('拒绝重定向到未授权域名：${next.host}');
        }
        uri = next;
        continue;
      }
      final bytes = response.data ?? const <int>[];
      if (bytes.length > scriptProviderMaxResponseBytes) {
        throw PluginException(
          '响应超过 ${scriptProviderMaxResponseBytes ~/ (1024 * 1024)} MiB',
        );
      }
      final contentType = response.headers.value('content-type') ?? '';
      final isText =
          request['expect'] == 'text' ||
          contentType.contains('json') ||
          contentType.startsWith('text/');
      return {
        'status': status,
        'headers': {
          for (final entry in response.headers.map.entries)
            entry.key: entry.value.join(','),
        },
        'body': isText
            ? utf8.decode(bytes, allowMalformed: true)
            : base64Encode(bytes),
        'bodyEncoding': isText ? 'text' : 'base64',
      };
    }
    throw const PluginException('重定向次数过多');
  }

  Future<Uint8List> _download(_ScriptRun run, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) throw const PluginException('图片地址不合法');
    _checkDownloadable(uri);
    final response = await _client.get<List<int>>(
      uri.toString(),
      options: Options(
        responseType: ResponseType.bytes,
        followRedirects: false,
        validateStatus: (_) => true,
      ),
      cancelToken: run.cancelToken,
    );
    if ((response.statusCode ?? 0) >= 300) {
      throw PluginException('下载图片失败（HTTP ${response.statusCode}）');
    }
    final bytes = response.data ?? const <int>[];
    if (bytes.isEmpty) throw const PluginException('图片内容为空');
    if (bytes.length > scriptProviderMaxResponseBytes) {
      throw PluginException(
        '图片超过 ${scriptProviderMaxResponseBytes ~/ (1024 * 1024)} MiB',
      );
    }
    return Uint8List.fromList(bytes);
  }
}

class _ScriptRun {
  final CancelToken cancelToken = CancelToken();
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    if (!cancelToken.isCancelled) cancelToken.cancel('cancelled');
  }

  void checkCancelled() {
    if (cancelled) throw const ProcessingCancelled();
  }
}
