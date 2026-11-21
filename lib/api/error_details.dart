import 'dart:convert';

/// 与网页工作台兼容的错误体解析；不包含请求头或请求正文。
String describeApiError(Object? payload, {int? status}) {
  Object? decode(Object? value) {
    if (value is String) {
      try { return jsonDecode(value); } catch (_) { return value; }
    }
    return value;
  }
  String? message(Object? value, [int depth = 0]) {
    if (depth > 8) return null;
    value = decode(value);
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    if (value is List) {
      final parts = value.map((e) => message(e, depth + 1)).whereType<String>().toList();
      return parts.isEmpty ? null : parts.join('；');
    }
    if (value is Map) {
      for (final key in ['message', 'detail']) {
        final found = message(value[key], depth + 1);
        if (found != null) return found;
      }
      final details = value['details'];
      final upstream = details is Map ? message(details['upstream_response'], depth + 1) : null;
      if (upstream != null) return upstream;
      for (final key in ['error', 'response', 'status_details', 'errors', 'msg']) {
        final found = message(value[key], depth + 1);
        if (found != null) return found;
      }
    }
    return null;
  }
  final decoded = decode(payload);
  final fields = <String, String>{};
  void collect(Object? value, [int depth = 0]) {
    if (depth > 8) return;
    value = decode(value);
    if (value is! Map) return;
    for (final key in ['code', 'type', 'param', 'request_id']) {
      final item = value[key];
      if (item is String || item is num) fields[key] = '$item';
    }
    for (final key in ['error', 'response', 'details', 'upstream_response']) { collect(value[key], depth + 1); }
  }
  collect(decoded);
  final code = fields['code']?.toLowerCase();
  final hint = switch (code) {
    'invalid_api_key' || 'authentication_error' => '密钥无效，请检查供应商密钥。',
    'insufficient_quota' || 'billing_hard_limit_reached' => '额度不足或达到消费上限，请检查余额与账单。',
    'rate_limit_exceeded' => '请求频率受限，请稍后手动重试。',
    'model_not_found' => '模型不存在或没有访问权限，请检查模型 ID。',
    'content_policy_violation' || 'moderation_blocked' => '内容被安全策略拦截，请调整提示词或参考图。',
    _ => switch (status) {
      400 || 422 => '请求参数不被接受，请检查模型、尺寸和参考图。',
      401 => '身份验证失败，请检查密钥。',
      403 => '没有访问权限，请检查供应商权限或内容限制。',
      404 => '接口或模型不存在，请检查 API 地址与模型 ID。',
      413 => '请求过大，请减少参考图或图片大小。',
      429 => '频率或额度受限，请检查余额并稍后手动重试。',
      int s when s >= 500 => '供应商服务异常，请稍后手动重试。',
      _ => null,
    },
  };
  Object? redact(Object? value, [int depth = 0]) {
    if (depth > 8) return '[嵌套内容已省略]';
    final parsed = decode(value);
    if (parsed is Map) return {for (final entry in parsed.entries) '${entry.key}': RegExp(r'^(api[_-]?key|authorization|access_token|refresh_token|secret|token)$', caseSensitive: false).hasMatch('${entry.key}') ? '[已隐藏]' : redact(entry.value, depth + 1)};
    if (parsed is List) return parsed.map((e) => redact(e, depth + 1)).toList();
    return parsed;
  }
  final safePayload = redact(decoded);
  return [
    message(decoded) ?? '服务端返回错误',
    if (status != null) 'HTTP 状态码：$status',
    for (final entry in fields.entries) '${entry.key}：${entry.value}',
    if (hint != null) '建议：$hint',
    '响应详情：${safePayload is Map || safePayload is List ? jsonEncode(safePayload) : safePayload}',
  ].join('\n');
}
