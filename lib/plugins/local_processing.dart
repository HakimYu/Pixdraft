import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../models/models.dart';
import 'plugin_contract.dart';

/// 内置本地处理插件：不联网、不覆盖原图，所有输出为 PNG。
const String builtinLocalPluginId = 'builtin.local-tools';
const String builtinLocalVersion = '1.0.0';

/// 单次处理输入上限：避免解码后内存爆掉。
const int localProcessingMaxBytes = 32 * 1024 * 1024;
const int localProcessingMaxPixels = 16000000;
const int localProcessingMaxSide = 8192;

const List<PluginField> resizeFields = [
  PluginField(key: 'width', label: '宽度（像素）', type: 'number', min: 1, max: 8192),
  PluginField(
    key: 'height',
    label: '高度（像素）',
    type: 'number',
    min: 1,
    max: 8192,
  ),
  PluginField(
    key: 'keepAspect',
    label: '保持比例',
    type: 'bool',
    defaultValue: true,
  ),
];

const List<PluginField> watermarkFields = [
  PluginField(key: 'text', label: '水印文字', type: 'text', defaultValue: '仅供预览'),
  PluginField(
    key: 'position',
    label: '位置',
    type: 'select',
    options: ['右下', '右上', '左下', '左上', '居中'],
    defaultValue: '右下',
  ),
  PluginField(
    key: 'opacity',
    label: '不透明度',
    type: 'number',
    min: 0.05,
    max: 1,
    defaultValue: 0.6,
  ),
  PluginField(
    key: 'scale',
    label: '文字大小（占短边比例）',
    type: 'number',
    min: 0.02,
    max: 0.6,
    defaultValue: 0.1,
  ),
  PluginField(
    key: 'color',
    label: '颜色',
    type: 'select',
    options: ['白色', '黑色'],
    defaultValue: '白色',
  ),
];

List<ImageProcessorExtension> createBuiltinProcessors() => [
  LocalImageProcessor(
    descriptor: const ProcessorDescriptor(
      id: 'local.resize',
      pluginId: builtinLocalPluginId,
      version: builtinLocalVersion,
      name: '调整尺寸',
      fields: resizeFields,
    ),
    operation: 'resize',
  ),
  LocalImageProcessor(
    descriptor: const ProcessorDescriptor(
      id: 'local.watermark',
      pluginId: builtinLocalPluginId,
      version: builtinLocalVersion,
      name: '添加水印',
      fields: watermarkFields,
    ),
    operation: 'watermark',
  ),
];

List<ToolDescriptor> builtinTools() => const [
  ToolDescriptor(
    id: 'tool.watermark',
    pluginId: builtinLocalPluginId,
    version: builtinLocalVersion,
    name: '批量水印',
    processorId: 'local.watermark',
    fields: watermarkFields,
  ),
  ToolDescriptor(
    id: 'tool.resize',
    pluginId: builtinLocalPluginId,
    version: builtinLocalVersion,
    name: '调整尺寸',
    processorId: 'local.resize',
    fields: resizeFields,
  ),
];

/// 内置处理器：读取输入、调用本地算法、先检查取消再保存新资产。
class LocalImageProcessor implements ImageProcessorExtension {
  const LocalImageProcessor({
    required this.descriptor,
    required this.operation,
  });
  @override
  final ProcessorDescriptor descriptor;
  final String operation;

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    context.checkCancelled();
    final bytes = await context.readImage(image);
    final result = await applyLocalImageOperation(bytes, operation, params);
    context.checkCancelled();
    return context.saveImage(result, 'image/png');
  }
}

/// 本地图片操作入口：参数与像素校验后交给后台 isolate 计算，返回 PNG 字节。
Future<Uint8List> applyLocalImageOperation(
  Uint8List bytes,
  String operation,
  Map<String, dynamic> params,
) async {
  if (bytes.isEmpty) throw const FormatException('图片内容为空');
  if (bytes.length > localProcessingMaxBytes) {
    throw const FormatException('图片超过 32 MB，无法本地处理');
  }
  final format = _detectFormat(bytes);
  if (format == null) throw const FormatException('无法识别的图片格式');
  if (format == 'svg') throw const FormatException('本地处理不支持 SVG 矢量图，请先转换为位图');
  if (format == 'gif') {
    throw const FormatException('本地处理暂不支持 GIF（可能包含动画），请先转换为 PNG');
  }
  final _Request request;
  switch (operation) {
    case 'resize':
      request = _ResizeRequest.fromParams(params);
    case 'watermark':
      request = await _WatermarkRequest.fromParams(params);
    default:
      throw FormatException('不支持的本地操作：$operation');
  }
  final Uint8List output;
  try {
    output = await Isolate.run(() => _transform(bytes, request));
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('图片处理失败，可能格式不受支持或内存不足');
  }
  if (output.isEmpty) throw const FormatException('图片处理失败，未生成结果');
  return output;
}

String? _detectFormat(Uint8List bytes) {
  bool startsWith(List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  if (startsWith([137, 80, 78, 71])) return 'png';
  if (startsWith([255, 216, 255])) return 'jpeg';
  if (startsWith([0x47, 0x49, 0x46])) return 'gif';
  if (bytes.length >= 12 && startsWith([0x52, 0x49, 0x46, 0x46]) && String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') return 'webp';
  if (String.fromCharCodes(bytes.sublist(0, math.min(bytes.length, 512))).contains('<svg')) return 'svg';
  return null;
}

// 参数校验

sealed class _Request {
  const _Request();
}

class _ResizeRequest extends _Request {
  const _ResizeRequest({this.width, this.height, this.keepAspect = true});
  final int? width, height;
  final bool keepAspect;

  factory _ResizeRequest.fromParams(Map<String, dynamic> params) {
    final width = _intParam(params, 'width', 1, localProcessingMaxSide);
    final height = _intParam(params, 'height', 1, localProcessingMaxSide);
    final keepAspect = _boolParam(params, 'keepAspect', defaultValue: true);
    if (width == null && height == null) {
      throw const FormatException('请至少填写宽度或高度');
    }
    if (width == null || height == null) {
      if (!keepAspect) {
        throw const FormatException('关闭保持比例时需同时填写宽度和高度');
      }
    }
    return _ResizeRequest(width: width, height: height, keepAspect: keepAspect);
  }
}

class _WatermarkRequest extends _Request {
  const _WatermarkRequest({
    required this.text,
    required this.position,
    required this.opacity,
    required this.scale,
    required this.tint,
    required this.mask,
    required this.maskWidth,
    required this.maskHeight,
  });
  final String text;
  final _WatermarkPosition position;
  final double opacity, scale;
  final int tint;
  final Uint8List mask;
  final int maskWidth, maskHeight;

  static Future<_WatermarkRequest> fromParams(
    Map<String, dynamic> params,
  ) async {
    final text = _stringParam(params, 'text');
    if (text.trim().isEmpty) throw const FormatException('请填写水印文字');
    if (text.runes.length > 120) throw const FormatException('水印文字最多 120 个字符');
    final position = _WatermarkPosition.parse(params);
    final opacity = _doubleParam(params, 'opacity', 0.05, 1, defaultValue: 0.6);
    final scale = _doubleParam(params, 'scale', 0.02, 0.6, defaultValue: 0.1);
    final tint = switch (params['color']) {
      null || '白色' || 'white' => 255,
      '黑色' || 'black' => 0,
      final Object other => throw FormatException('水印颜色不支持：$other'),
    };
    final mask = await _renderTextMask(text);
    if (mask == null) throw const FormatException('无法渲染水印文字，请检查内容');
    return _WatermarkRequest(
      text: text,
      position: position,
      opacity: opacity,
      scale: scale,
      tint: tint,
      mask: mask.rgba,
      maskWidth: mask.width,
      maskHeight: mask.height,
    );
  }
}

enum _WatermarkPosition {
  topLeft('左上'),
  topRight('右上'),
  bottomLeft('左下'),
  bottomRight('右下'),
  center('居中');

  const _WatermarkPosition(this.label);
  final String label;

  static _WatermarkPosition parse(Map<String, dynamic> params) {
    final value = params['position'];
    if (value == null) return _WatermarkPosition.bottomRight;
    for (final position in _WatermarkPosition.values) {
      if (value == position.label || value == position.name) return position;
    }
    throw FormatException('水印位置不支持：$value');
  }
}

String _stringParam(Map<String, dynamic> params, String key) {
  final value = params[key];
  if (value is String) return value;
  throw FormatException('$key 必须是文本');
}

int? _intParam(Map<String, dynamic> params, String key, int min, int max) {
  final value = params[key];
  if (value == null) return null;
  final number = switch (value) {
    final int v => v,
    final double v when v == v.roundToDouble() => v.round(),
    _ => throw FormatException('$key 必须是整数'),
  };
  if (number < min || number > max) {
    throw FormatException('$key 需在 $min–$max 之间');
  }
  return number;
}

double _doubleParam(
  Map<String, dynamic> params,
  String key,
  double min,
  double max, {
  required double defaultValue,
}) {
  final value = params[key];
  if (value == null) return defaultValue;
  final number = switch (value) {
    final num v => v.toDouble(),
    _ => throw FormatException('$key 必须是数字'),
  };
  if (number.isNaN || number < min || number > max) {
    throw FormatException('$key 需在 $min–$max 之间');
  }
  return number;
}

bool _boolParam(
  Map<String, dynamic> params,
  String key, {
  required bool defaultValue,
}) {
  final value = params[key];
  if (value == null) return defaultValue;
  if (value is bool) return value;
  throw FormatException('$key 必须是开关值');
}

// 文本位图

typedef _TextMask = ({Uint8List rgba, int width, int height});

/// 在宿主 isolate 用 Flutter 排版把文字栅格化成极小的透明位图，像素合成放到 isolate 里做。
Future<_TextMask?> _renderTextMask(String text) async {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        fontSize: 96,
        height: 1.15,
        fontWeight: FontWeight.w700,
        color: Color(0xFFFFFFFF),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 2400);
  final width = painter.width.ceil().clamp(1, 4096);
  final height = painter.height.ceil().clamp(1, 4096);
  final recorder = ui.PictureRecorder();
  try {
    painter.paint(Canvas(recorder), Offset.zero);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) return null;
      final rgba = data.buffer.asUint8List();
      return (rgba: Uint8List.fromList(rgba), width: width, height: height);
    } finally {
      image.dispose();
    }
  } finally {
    painter.dispose();
  }
}

// isolate 计算

Uint8List _transform(Uint8List bytes, _Request request) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('图片内容无法解码，可能格式不受支持');
  final source = img.bakeOrientation(decoded);
  if (source.width > localProcessingMaxSide ||
      source.height > localProcessingMaxSide ||
      source.width * source.height > localProcessingMaxPixels) {
    throw const FormatException('图片尺寸超过本地处理上限（单边 8192、合计 1600 万像素）');
  }
  final result = switch (request) {
    _ResizeRequest r => _resize(source, r),
    _WatermarkRequest r => _watermark(source, r),
  };
  return img.encodePng(result, level: 6);
}

img.Image _resize(img.Image source, _ResizeRequest request) {
  int width, height;
  if (request.width != null && request.height != null) {
    if (request.keepAspect) {
      final scale = math.min(
        request.width! / source.width,
        request.height! / source.height,
      );
      width = math.max(1, (source.width * scale).round());
      height = math.max(1, (source.height * scale).round());
    } else {
      width = request.width!;
      height = request.height!;
    }
  } else if (request.width != null) {
    width = request.width!;
    height = math.max(
      1,
      (source.height * request.width! / source.width).round(),
    );
  } else {
    height = request.height!;
    width = math.max(
      1,
      (source.width * request.height! / source.height).round(),
    );
  }
  if (width > localProcessingMaxSide ||
      height > localProcessingMaxSide ||
      width * height > localProcessingMaxPixels) {
    throw const FormatException('输出尺寸超过本地处理上限（单边 8192、合计 1600 万像素）');
  }
  return img.copyResize(
    source,
    width: width,
    height: height,
    interpolation: img.Interpolation.linear,
  );
}

img.Image _watermark(img.Image source, _WatermarkRequest request) {
  final shortSide = math.min(source.width, source.height);
  final margin = math.max(6, (shortSide * 0.03).round());
  var targetHeight = math.max(8, (shortSide * request.scale).round());
  var targetWidth = math.max(
    1,
    (request.maskWidth * targetHeight / request.maskHeight).round(),
  );
  final maxWidth = math.max(1, source.width - margin * 2);
  if (targetWidth > maxWidth) {
    targetHeight = math.max(2, (targetHeight * maxWidth / targetWidth).round());
    targetWidth = maxWidth;
  }
  if (targetHeight > source.height - margin * 2) {
    targetHeight = math.max(2, source.height - margin * 2);
  }

  final mask = img.copyResize(
    img.Image.fromBytes(
      width: request.maskWidth,
      height: request.maskHeight,
      bytes: request.mask.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    ),
    width: targetWidth,
    height: targetHeight,
    interpolation: img.Interpolation.cubic,
  );
  final (left, top) = switch (request.position) {
    _WatermarkPosition.topLeft => (margin, margin),
    _WatermarkPosition.topRight => (
      math.max(margin, source.width - margin - targetWidth),
      margin,
    ),
    _WatermarkPosition.bottomLeft => (
      margin,
      math.max(margin, source.height - margin - targetHeight),
    ),
    _WatermarkPosition.bottomRight => (
      math.max(margin, source.width - margin - targetWidth),
      math.max(margin, source.height - margin - targetHeight),
    ),
    _WatermarkPosition.center => (
      (source.width - targetWidth) ~/ 2,
      (source.height - targetHeight) ~/ 2,
    ),
  };

  final out = source.convert(numChannels: 4);
  for (var y = 0; y < targetHeight; y++) {
    final canvasY = top + y;
    if (canvasY < 0 || canvasY >= out.height) continue;
    for (var x = 0; x < targetWidth; x++) {
      final canvasX = left + x;
      if (canvasX < 0 || canvasX >= out.width) continue;
      final alpha = (mask.getPixel(x, y).a.toDouble() / 255) * request.opacity;
      if (alpha <= 0) continue;
      final pixel = out.getPixel(canvasX, canvasY);
      out.setPixelRgba(
        canvasX,
        canvasY,
        (pixel.r * (1 - alpha) + request.tint * alpha).round(),
        (pixel.g * (1 - alpha) + request.tint * alpha).round(),
        (pixel.b * (1 - alpha) + request.tint * alpha).round(),
        pixel.a,
      );
    }
  }
  return out;
}
