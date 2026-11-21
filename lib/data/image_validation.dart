import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';

String detectImageMime(Uint8List bytes) {
  if (bytes.length >= 8 && bytes[0] == 137 && bytes[1] == 80) return 'image/png';
  if (bytes.length >= 3 && bytes[0] == 255 && bytes[1] == 216) return 'image/jpeg';
  if (bytes.length >= 6 && ascii.decode(bytes.sublist(0, 3), allowInvalid: true) == 'GIF') return 'image/gif';
  if (bytes.length >= 12 && ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') return 'image/webp';
  if (utf8.decode(bytes, allowMalformed: true).contains('<svg')) return 'image/svg+xml';
  throw const FormatException('无法识别图片格式');
}
Future<({int? width, int? height})> validateImage(Uint8List bytes, String mime) async {
  if (bytes.isEmpty || bytes.length > 64 * 1024 * 1024) throw const FormatException('图片格式或大小无效（最多 64 MB）');
  bool starts(List<int> magic) => bytes.length >= magic.length && List.generate(magic.length, (i) => bytes[i] == magic[i]).every((v) => v);
  if (mime == 'image/svg+xml') {
    final svg = utf8.decode(bytes);
    if (!RegExp(r'<svg(?:\s|>)').hasMatch(svg) || RegExp(r'<!DOCTYPE|<!ENTITY|<script|<foreignObject|(?:href|src)\s*=\s*["\x27]\s*(?:https?:|//|file:)|url\s*\(', caseSensitive: false).hasMatch(svg)) throw const FormatException('SVG 内容无效或含外部资源');
    try { await SvgStringLoader(svg).loadBytes(null); } catch (_) { throw const FormatException('SVG 内容无法解析'); }
    return (width: null, height: null);
  }
  final matches = switch (mime) {
    'image/png' => starts([137, 80, 78, 71, 13, 10, 26, 10]),
    'image/jpeg' => starts([255, 216, 255]),
    'image/gif' => starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a')),
    'image/webp' => starts(ascii.encode('RIFF')) && bytes.length >= 12 && ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP',
    _ => false,
  };
  if (!matches) throw const FormatException('图片内容与格式不符');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width <= 0 || descriptor.height <= 0 || descriptor.width * descriptor.height > 64000000) throw const FormatException('图片尺寸无效或超过 6400 万像素');
    codec = await descriptor.instantiateCodec(targetWidth: descriptor.width > 64 ? 64 : descriptor.width);
    final frame = await codec.getNextFrame();
    frame.image.dispose();
    return (width: descriptor.width, height: descriptor.height);
  } on FormatException { rethrow; } catch (_) {
    throw const FormatException('图片内容无法解码');
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
