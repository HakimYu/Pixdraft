import 'dart:convert';

import 'package:dio/dio.dart';

import '../../api/network_dio.dart';
import '../../api/async_image_models.dart';
import '../../models/models.dart';

/// 仅用于检查 `/models` 的可达性，不发起任何生图请求。
enum ModelCheckStatus {
  ok,
  noModelEndpoint,
  unauthorized,
  redirected,
  invalidResponse,
  failed,
}

class ModelCheckResult {
  const ModelCheckResult(this.status, this.message, {
    this.models = const [],
    this.imageSchemas = const {},
  });

  final ModelCheckStatus status;
  final String message;
  final List<String> models;
  final Map<String, dynamic> imageSchemas;
}

/// 保留用户填写的路径前缀（如 `/openai/v1`）；空路径按 OpenAI 约定补 `/v1`。
Uri? modelsUri(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final target = path.isEmpty
      ? '${uri.origin}/v1/models'
      : '${uri.origin}$path/models';
  return Uri.tryParse(target);
}

class ProviderModelChecker {
  ProviderModelChecker({Dio? dio})
    : _dio = dio ?? createNetworkDio(),
      _selfOwnsDio = dio == null;

  final Dio _dio;
  final bool _selfOwnsDio;
  static const _timeout = Duration(seconds: 20);

  Future<ModelCheckResult> check(
    ProviderConfig provider,
    String? apiKey,
  ) async {
    final base = provider.protocol == ApiProtocol.wavespeed && Uri.tryParse(provider.baseUrl)?.path.replaceAll('/', '').isEmpty == true ? '${provider.baseUrl.replaceAll(RegExp(r"/+$"), "")}/api/v3' : provider.baseUrl;
    final uri = modelsUri(base);
    if (uri == null) {
      return const ModelCheckResult(
        ModelCheckStatus.failed,
        'API 地址无效，无法检查连接。',
      );
    }
    final key = apiKey?.trim() ?? '';
    try {
      final response = await _dio.getUri<dynamic>(
        uri,
        options: Options(
          // 不跟随重定向，避免 Authorization 在跨域跳转时泄露。
          followRedirects: false,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null,
          connectTimeout: _timeout,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          headers: {if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
        ),
      );
      return _interpret(response, provider.protocol);
    } on DioException catch (error) {
      final response = error.response;
      if (response != null) return _interpret(response, provider.protocol);
      final timedOut =
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout;
      return ModelCheckResult(
        ModelCheckStatus.failed,
        timedOut ? '连接超时，请检查网络或服务地址；这不代表生图不可用。' : '无法连接到服务，请检查地址、网络和服务的跨域（CORS）设置；这不代表生图不可用。',
      );
    }
  }

  ModelCheckResult _interpret(Response<dynamic> response, ApiProtocol protocol) {
    final code = response.statusCode ?? 0;
    if (code >= 300 && code < 400) {
      return const ModelCheckResult(
        ModelCheckStatus.redirected,
        '服务返回重定向，已停止跟随以避免泄露密钥；无法检查模型列表。',
      );
    }
    if (code == 401 || code == 403) {
      return ModelCheckResult(
        ModelCheckStatus.unauthorized,
        '密钥无效或无权访问模型列表（HTTP $code），请检查密钥。',
      );
    }
    if (code == 400 || code == 404 || code == 405 || code == 501) {
      return ModelCheckResult(
        ModelCheckStatus.noModelEndpoint,
        '该服务未提供 /models 接口（HTTP $code），无法检查模型列表；这不代表生图不可用。',
      );
    }
    if (code < 200 || code >= 300) {
      return ModelCheckResult(
        ModelCheckStatus.failed,
        '服务返回 HTTP $code，无法检查模型列表；这不代表生图不可用。',
      );
    }

    Object? payload = response.data;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } on FormatException {
        // 保持原值，下面按无法识别处理。
      }
    }
    final list = payload is Map ? payload['data'] : null;
    if (list is! List) {
      return const ModelCheckResult(
        ModelCheckStatus.invalidResponse,
        '服务已响应，但未返回可识别的模型列表；这不代表生图不可用。',
      );
    }
    final wave = protocol == ApiProtocol.wavespeed;
    final models = <String>{};
    final schemas = <String, dynamic>{};
    for (final item in list.whereType<Map>()) {
      final waveId = item['model_id'];
      if (wave && waveId is String) {
        if (item['type'] != null && !waveImageTypes.contains(item['type'])) continue;
        models.add(waveId);
        final schema = waveImageSchema(item);
        if (schema != null) schemas[waveId] = schema;
      } else if (item['id'] case final String id) {
        models.add(id);
      }
    }
    return ModelCheckResult(
      ModelCheckStatus.ok,
      models.isEmpty
          ? '连接正常，未返回模型；仅检查了 /models，未发起生图请求。'
          : '连接正常，共 ${models.length} 个模型；仅检查了 /models，未发起生图请求。',
      models: models.toList(),
      imageSchemas: schemas,
    );
  }

  void close() {
    if (_selfOwnsDio) _dio.close(force: true);
  }
}
