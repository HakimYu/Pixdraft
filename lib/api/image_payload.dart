import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'params.dart';

class ImagePayload {
  const ImagePayload({required this.signature, this.bytes, this.url, required this.mime});

  final String signature;
  final Uint8List? bytes;
  final String? url;
  final String mime;
}

class ImageBatch {
  const ImageBatch(this.images, {required this.hadPayload});

  final List<ImagePayload> images;
  final bool hadPayload;
}

/// 遍历响应载荷，按跨事件共享的签名去重并解码图片。
class ImageCollector {
  ImageCollector({required this.fallbackMime, required this.seen});

  final String fallbackMime;
  final Set<String> seen;
  final List<Map<String, String>> _calls = [];
  final Set<String> _callKeys = {};

  ImageBatch collect(Object? payload) {
    final images = <ImagePayload>[];
    var hadPayload = false;

    void walk(Object? node) {
      if (node is List) {
        for (final item in node) {
          walk(item);
        }
        return;
      }
      if (node is! Map) return;
      _recordCall(node);
      final image = _payloadFor(node);
      if (image != null) {
        hadPayload = true;
        if (seen.add(image.signature)) images.add(image);
      }
      for (final key in const ['data', 'output', 'content']) {
        final child = node[key];
        if (child is List) walk(child);
      }
      for (final key in const ['item', 'response']) {
        final child = node[key];
        if (child is Map) walk(child);
      }
    }

    walk(payload);
    return ImageBatch(images, hadPayload: hadPayload);
  }

  Map<String, dynamic>? get appliedMetadata {
    if (_calls.isEmpty) return null;
    final applied = <String, dynamic>{};
    for (final key in const ['size', 'quality', 'output_format', 'background', 'action']) {
      final values = <String>[];
      for (final call in _calls) {
        final value = call[key];
        if (value != null && value.isNotEmpty && !values.contains(value)) values.add(value);
      }
      if (values.isNotEmpty) applied[key] = values.join(' / ');
    }
    String? revised;
    for (final call in _calls) {
      final value = call['revised_prompt'];
      if (value != null && value.isNotEmpty) {
        revised = value;
        break;
      }
    }
    final result = <String, dynamic>{};
    if (applied.isNotEmpty) result['appliedImageParams'] = applied;
    if (revised != null) result['revisedPrompt'] = revised;
    return result.isEmpty ? null : result;
  }

  void _recordCall(Map<dynamic, dynamic> record) {
    final type = record['type'];
    final looksLikeCall = type == 'image_generation_call' ||
        record.containsKey('revised_prompt') ||
        (record.containsKey('size') && record.containsKey('output_format'));
    if (!looksLikeCall) return;
    final call = <String, String>{};
    for (final key in const ['size', 'quality', 'output_format', 'background', 'action', 'revised_prompt']) {
      final value = record[key];
      if (value is String && value.isNotEmpty) call[key] = value;
    }
    if (call.isEmpty) return;
    if (_callKeys.add(jsonEncode(call))) _calls.add(call);
  }

  ImagePayload? _payloadFor(Map<dynamic, dynamic> record) {
    final type = record['type'];
    if (type is String && type.contains('partial_image')) return null;

    final signature = _signatureFor(record);
    if (signature == null) return null;

    final b64 = _nonEmpty(record['b64_json']) ?? _nonEmpty(record['result']);
    if (b64 != null) {
      if (b64.startsWith('data:')) {
        final decoded = _decodeDataUrl(b64);
        return ImagePayload(signature: signature, bytes: decoded.bytes, mime: decoded.mime);
      }
      return ImagePayload(
        signature: signature,
        bytes: _decodeBase64(b64),
        mime: _mimeFor(record['output_format']) ?? fallbackMime,
      );
    }

    final href = _nonEmpty(record['url']) ?? _nonEmpty(record['image_url']);
    if (href == null) return null;
    if (href.startsWith('data:')) {
      final decoded = _decodeDataUrl(href);
      return ImagePayload(signature: signature, bytes: decoded.bytes, mime: decoded.mime);
    }
    if (href.startsWith('http://') || href.startsWith('https://')) {
      return ImagePayload(
        signature: signature,
        url: href,
        mime: _mimeFor(record['output_format']) ?? fallbackMime,
      );
    }
    throw const FormatException('接口返回了不支持的图片地址');
  }

  String? _signatureFor(Map<dynamic, dynamic> record) {
    final id = record['id'];
    if (id is String && id.isNotEmpty) {
      final index = record['output_index'];
      return index is num ? 'id:$id:output_index:${index.toInt()}' : 'id:$id';
    }
    for (final field in const ['b64_json', 'result']) {
      final value = record[field];
      if (value is String && value.isNotEmpty) return _contentSignature(field, value);
    }
    final url = record['url'];
    if (url is String && url.isNotEmpty) return 'url:$url';
    final imageUrl = record['image_url'];
    if (imageUrl is String && imageUrl.isNotEmpty) return 'image_url:$imageUrl';
    return null;
  }

  String _contentSignature(String prefix, String value) {
    final compact = value.replaceAll(RegExp(r'\s'), '');
    return '$prefix:${sha256.convert(utf8.encode(compact))}';
  }

  String? _mimeFor(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final format = value.trim().toLowerCase();
    if (format.startsWith('image/')) return format;
    return mimeForFormat(format);
  }

  String? _nonEmpty(Object? value) => value is String && value.isNotEmpty ? value : null;

  Uint8List _decodeBase64(String value) {
    final compact = value.replaceAll(RegExp(r'\s'), '');
    late Uint8List bytes;
    try {
      bytes = base64Decode(compact);
    } on FormatException {
      throw const FormatException('图片 base64 数据格式无效');
    }
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    return bytes;
  }

  ({Uint8List bytes, String mime}) _decodeDataUrl(String value) {
    final comma = value.indexOf(',');
    if (comma < 0) throw const FormatException('图片 data URL 格式无效');
    final header = value.substring(5, comma);
    final body = value.substring(comma + 1);
    final parts = header.split(';');
    final declared = parts.isNotEmpty && parts.first.isNotEmpty ? parts.first.toLowerCase() : fallbackMime;
    final mime = declared.startsWith('image/') ? declared : fallbackMime;
    final isBase64 = parts.any((part) => part.trim().toLowerCase() == 'base64');
    if (isBase64) return (bytes: _decodeBase64(body), mime: mime);
    final bytes = Uint8List.fromList(utf8.encode(Uri.decodeComponent(body)));
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    return (bytes: bytes, mime: mime);
  }
}
