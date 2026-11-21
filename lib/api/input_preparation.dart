import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 内联参考图超过该大小时才尝试压缩。
const int inlineImageThresholdBytes = 700 * 1024;

/// 压缩后最长边上限。
const int inlineImageMaxEdge = 2048;

/// 继续缩小时最长边下限。
const int inlineImageMinEdge = 256;

/// 单张图片解码前的像素上限，避免解码超大图占满内存。
const int inlineImageMaxPixels = 64 * 1000 * 1000;

/// 单张资产读取上限，避免一次性读入超大文件。
const int maxReadAssetBytes = 64 * 1024 * 1024;

/// 单批原始资产读取总量上限（16 张参考图的极端情况）。
const int maxReadBatchBytes = 128 * 1024 * 1024;

const _compressibleMimes = {'image/png', 'image/jpeg', 'image/webp'};

/// 把大于阈值的 PNG/JPEG/WebP 参考图缩到最长边 [maxEdge] 并编码为 PNG；
/// 仍超阈值时按比例继续缩小，但不小于 [minEdge]。
///
/// 返回 `null` 表示应保留原图：未超过阈值、格式不可压缩（如 GIF 保留动画）、
/// 输出并不比原图更小，或已缩到下限。
///
/// 方向由 codec 依 EXIF 处理，返回图与显示方向一致；透明通道保留。
/// 像素数超过 [maxPixels] 或无法解码时抛出 [FormatException]。
Future<({Uint8List bytes, String mime})?> prepareInlineImage(
  Uint8List bytes,
  String mime, {
  int thresholdBytes = inlineImageThresholdBytes,
  int maxEdge = inlineImageMaxEdge,
  int minEdge = inlineImageMinEdge,
  int maxPixels = inlineImageMaxPixels,
}) async {
  if (bytes.length <= thresholdBytes) return null;
  if (!_compressibleMimes.contains(mime.trim().toLowerCase())) return null;

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } catch (_) {
      throw const FormatException('无法解析参考图，无法压缩为内联图片');
    }

    final width = descriptor.width;
    final height = descriptor.height;
    if (width <= 0 || height <= 0) {
      throw const FormatException('参考图尺寸无效');
    }
    if (width * height > maxPixels) {
      throw const FormatException('参考图超过 6400 万像素，无法处理');
    }

    var renderEdge = math.min(math.max(width, height), maxEdge);
    while (true) {
      final encoded = await _encodePng(descriptor, width, height, renderEdge);
      if (encoded.length <= thresholdBytes) {
        // 原 bytes 更小时保留原图。
        if (encoded.length >= bytes.length) return null;
        return (bytes: encoded, mime: 'image/png');
      }
      if (renderEdge <= minEdge) return null;
      renderEdge = math.max(minEdge, (renderEdge * 0.8).floor());
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('无法压缩参考图，已保留原图');
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<Uint8List> _encodePng(
  ui.ImageDescriptor descriptor,
  int width,
  int height,
  int renderEdge,
) async {
  final scale = renderEdge / math.max(width, height);
  final targetWidth = math.max(1, (width * scale).round());
  final targetHeight = math.max(1, (height * scale).round());
  final codec = await descriptor.instantiateCodec(
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('PNG 编码失败');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
