import 'dart:convert';

import '../models/models.dart';
import 'params.dart';

/// 单次请求尝试的脱敏快照。
class ErrorAttempt {
  ErrorAttempt({
    required this.url,
    required this.transport,
    required this.body,
    required this.compat,
    required this.elapsed,
    this.status,
    this.requestId,
    this.response,
    this.error,
  });

  /// 已脱敏的请求地址（不含查询串和片段）。
  final String url;
  final String transport;
  final String body;
  final bool compat;
  final Duration elapsed;
  final int? status;
  final String? requestId;
  final String? response;
  final String? error;

  String render() {
    final result = StringBuffer('POST $url（$transport/$body');
    if (compat) result.write('，兼容参数');
    result.write('）→ ');
    if (status != null) result.write('HTTP $status');
    if (requestId != null) result.write('${status == null ? '' : '，'}request_id: $requestId');
    result.write('，用时 ${formatSeconds(elapsed)}');
    final lines = <String>[result.toString()];
    if (response != null && response!.isNotEmpty) lines.add('  响应：$response');
    if (error != null) lines.add('  错误：$error');
    return lines.join('\n');
  }
}

/// 失败请求的可诊断上下文。
///
/// 只在最终失败时渲染到错误信息里，内容经过脱敏与长度限制：
/// 不包含图片 base64、二进制、密钥、Bearer 令牌和签名查询串。
class ErrorContext {
  ErrorContext(GenerationInput input, {DateTime? startedAt})
    : startedAt = startedAt ?? DateTime.now(),
      baseUrl = summarizeUrlString(input.provider.baseUrl),
      apiProtocol = input.provider.protocol.name,
      requestedTransport = input.provider.transport.name,
      timeoutSeconds = input.provider.timeoutSeconds,
      fileInput = input.provider.fileInput,
      promptCompatibility = input.provider.promptCompatibility,
      responseModel = input.provider.responseModel,
      prompt = input.prompt;

  static const int _maxAttempts = 12;
  static const int _maxNotes = 12;

  final DateTime startedAt;
  final String baseUrl;
  final String apiProtocol;
  final String requestedTransport;
  final int timeoutSeconds;
  final bool fileInput;
  final bool promptCompatibility;
  final String responseModel;
  final String prompt;
  final List<ErrorAttempt> _attempts = [];
  final List<String> _notes = [];
  final List<String> _assets = [];
  var _droppedAttempts = 0;

  String? model;
  ResolvedParams? params;

  void note(String message) {
    if (_notes.length >= _maxNotes) return;
    final value = summarizeLogString(message, limit: 300);
    if (!_notes.contains(value)) _notes.add(value);
  }

  void record({
    required Uri url,
    required Duration elapsed,
    String transport = 'json',
    String body = 'json',
    bool compat = false,
    int? status,
    String? requestId,
    String? response,
    String? error,
  }) {
    if (_attempts.length >= _maxAttempts) {
      _droppedAttempts++;
      return;
    }
    _attempts.add(
      ErrorAttempt(
        url: summarizeUrl(url),
        transport: transport,
        body: body,
        compat: compat,
        elapsed: elapsed,
        status: status,
        requestId: requestId == null
            ? null
            : summarizeLogString(requestId, limit: 120),
        response: response == null
            ? null
            : summarizeLogString(response, limit: 800),
        error: error == null
            ? null
            : summarizeLogString(error, limit: 200),
      ),
    );
  }

  void setAssets({
    required List<({String mime, int bytes, bool inline})> references,
    ({String mime, int bytes})? mask,
    ({String mime, int bytes})? markup,
  }) {
    _assets.clear();
    if (references.isNotEmpty) {
      final shown = references
          .take(4)
          .map((item) => '${item.mime} ${formatBytes(item.bytes)}${item.inline ? '（已压缩内联）' : ''}')
          .join('、');
      final extra = references.length > 4 ? ' 等 ${references.length} 张' : '';
      _assets.add('参考图 ${references.length} 张：$shown$extra');
    }
    if (mask != null) _assets.add('蒙版：${mask.mime} ${formatBytes(mask.bytes)}');
    if (markup != null) {
      _assets.add('标注：${markup.mime} ${formatBytes(markup.bytes)}');
    }
  }

  String render() {
    final lines = <String>['诊断信息'];
    final total = DateTime.now().difference(startedAt);
    lines.add('时间：${startedAt.toIso8601String()}（总耗时 ${formatSeconds(total)}）');
    lines.add(
      '协议：$apiProtocol；请求模式：$requestedTransport；'
      '模型：${model ?? '未解析'}；超时：$timeoutSeconds 秒',
    );
    final resolved = params;
    if (resolved != null) lines.add('参数：${_paramsSummary(resolved)}');
    if (prompt.trim().isNotEmpty) {
      lines.add(
        '提示词：${summarizeLogString(prompt, limit: 160)}'
        '（共 ${prompt.length} 字符）',
      );
    }
    lines.addAll(_assets);
    if (apiProtocol == ApiProtocol.responses.name) {
      lines.add('Responses 模型：${summarizeLogString(responseModel, limit: 120)}');
      lines.add('响应输入方式：${fileInput ? 'file_id 上传' : '内联图片'}');
    }
    if (baseUrl.isNotEmpty) lines.add('服务地址：$baseUrl');
    if (_attempts.isNotEmpty) {
      lines.add('请求：');
      for (var i = 0; i < _attempts.length; i++) {
        lines.add('${i + 1}. ${_attempts[i].render()}');
      }
      if (_droppedAttempts > 0) {
        lines.add('…其余 $_droppedAttempts 次尝试已省略');
      }
    }
    if (_notes.isNotEmpty) lines.add('说明：${_notes.join('；')}');
    return lines.join('\n');
  }

  String _paramsSummary(ResolvedParams value) => [
    'size=${value.size}',
    'quality=${value.quality}',
    'format=${value.format}',
    'count=${value.count}',
    if (value.background.isNotEmpty) 'background=${value.background}',
    if (value.moderation.isNotEmpty) 'moderation=${value.moderation}',
    if (value.hasCompression) 'compression=${value.compression}',
    if (value.format == 'gif')
      'gif=${value.gifFrames} 帧/${value.gifDuration} 毫秒',
    if (value.inputFidelity != null) 'input_fidelity=${value.inputFidelity}',
    if (value.complexity != null) 'complexity=${value.complexity}',
  ].join('，');
}

String formatSeconds(Duration duration) =>
    '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} 秒';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 将请求地址收敛为 `scheme://host[:port]/path`，丢弃用户信息和查询串。
String summarizeUrl(Uri uri) {
  final result = StringBuffer();
  if (uri.scheme.isNotEmpty) result.write('${uri.scheme}://');
  result.write(uri.host);
  if (uri.hasPort) result.write(':${uri.port}');
  result.write(uri.path.isEmpty ? '/' : uri.path);
  if (uri.hasQuery) result.write('?…已隐藏');
  if (uri.hasFragment) result.write('#…已隐藏');
  return result.toString();
}

/// 对文本中的任意地址做同样的脱敏，无法解析时整体隐藏。
String summarizeUrlString(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.host.isEmpty) return '[地址已隐藏]';
  return summarizeUrl(uri);
}

/// 响应体摘要：JSON 先结构化脱敏，非 JSON 直接脱敏并截断。
String summarizeResponseBody(String text, {int limit = 800}) {
  if (text.trim().isEmpty) return '（空响应）';
  try {
    final decoded = jsonDecode(text);
    return summarizeLogString(jsonEncode(sanitizeLogValue(decoded)), limit: limit);
  } on FormatException {
    // 非 JSON，按文本处理。
  }
  return summarizeLogString(text, limit: limit);
}

const int _stringLimit = 1200;
const int _maxDepth = 5;
const int _maxItems = 10;
const int _maxKeys = 30;

/// 与参考实现一致的敏感字段判断。
final RegExp _sensitiveKeyPattern = RegExp(
  r'authorization|api[-_]?key|cookie|token|secret|password',
  caseSensitive: false,
);

final RegExp _bearerPattern = RegExp(
  r'Bearer\s+[A-Za-z0-9._~+/=\-]+',
  caseSensitive: false,
);

/// 有界地脱敏任意日志值。
Object? sanitizeLogValue(Object? value, [int depth = 0]) {
  if (value == null || value is num || value is bool) return value;
  if (value is String) return summarizeLogString(value);
  if (depth >= _maxDepth) return '[已达到最大深度]';
  if (value is List) {
    final result = <Object?>[
      for (final item in value.take(_maxItems)) sanitizeLogValue(item, depth + 1),
    ];
    if (value.length > _maxItems) {
      result.add('[+${value.length - _maxItems} 项已省略]');
    }
    return result;
  }
  if (value is Map) {
    final result = <String, Object?>{};
    var count = 0;
    for (final entry in value.entries) {
      if (count >= _maxKeys) {
        result['__已省略键'] = value.length - _maxKeys;
        break;
      }
      final key = '${entry.key}';
      result[key] = _sensitiveKeyPattern.hasMatch(key)
          ? '[已隐藏]'
          : sanitizeLogValue(entry.value, depth + 1);
      count++;
    }
    return result;
  }
  return summarizeLogString('$value');
}

/// 隐藏令牌、data URL 与长 base64，并按 [limit] 截断。
String summarizeLogString(String value, {int limit = _stringLimit}) {
  var text = value.replaceAll(_bearerPattern, 'Bearer [已隐藏]');
  text = hideBinaryPayloads(text);
  if (text.length <= limit) return text;
  final kept = String.fromCharCodes(text.runes.take(limit));
  return '$kept…（已截断 ${text.length - limit} 字符）';
}
/// 只隐藏图片数据与长 base64，不截断文本。
String hideBinaryPayloads(String value) => _hideBase64Runs(_hideDataUrls(value));

String _hideDataUrls(String text) {
  final out = StringBuffer();
  var index = 0;
  while (index < text.length) {
    final start = text.indexOf('data:', index);
    if (start < 0) {
      out.write(text.substring(index));
      break;
    }
    final comma = text.indexOf(',', start);
    if (comma < 0 || comma - start > 300) {
      out.write(text.substring(index, start + 5));
      index = start + 5;
      continue;
    }
    if (!text.substring(start + 5, comma).toLowerCase().contains('base64')) {
      out.write(text.substring(index, comma + 1));
      index = comma + 1;
      continue;
    }
    final meta = text.substring(start + 5, comma);
    var end = comma + 1;
    while (end < text.length && _isBase64Char(text.codeUnitAt(end))) {
      end++;
    }
    out.write(text.substring(index, start));
    out.write(
      '[数据图片 mime=${meta.split(';').first} '
      '约 ${end - comma - 1} 字符，内容已隐藏]',
    );
    index = end;
  }
  return out.toString();
}

String _hideBase64Runs(String text) {
  final out = StringBuffer();
  var index = 0;
  while (index < text.length) {
    if (!_isBase64Char(text.codeUnitAt(index))) {
      out.writeCharCode(text.codeUnitAt(index));
      index++;
      continue;
    }
    var end = index;
    while (end < text.length && _isBase64Char(text.codeUnitAt(end))) {
      end++;
    }
    final length = end - index;
    if (length >= 600) {
      out.write('[base64 长度 $length 已隐藏]');
    } else {
      out.write(text.substring(index, end));
    }
    index = end;
  }
  return out.toString();
}

bool _isBase64Char(int code) =>
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122) ||
    (code >= 48 && code <= 57) ||
    code == 43 ||
    code == 47 ||
    code == 61 ||
    code == 45 ||
    code == 95;
