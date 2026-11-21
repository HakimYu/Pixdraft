import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../models/models.dart';
import 'editor_geometry.dart';

/// 编辑与导出的像素上限，防止超大图在编码时耗尽内存。
/// 1600 万像素约等于 4000×4000，覆盖常见手机原图。
const int editPixelLimit = 16000000;

/// 可作为位图编辑的源图格式。GIF（动图）与 SVG（矢量）不支持。
const Set<String> editableMimes = {'image/png', 'image/jpeg', 'image/webp'};

bool canEditAsset(ImageAsset asset) => editableMimes.contains(asset.mime);

String unsupportedMessage(String mime) {
  if (mime == 'image/gif') return 'GIF 动图暂不支持局部编辑，请先转换为 PNG';
  if (mime == 'image/svg+xml') {
    return 'SVG 为矢量格式，无法编辑位图蒙版，请先转换为 PNG';
  }
  return '当前格式不支持局部编辑，请先转换为 PNG、JPEG 或 WebP';
}

String oversizedMessage(int width, int height) =>
    '图片过大（$width×$height，超过 ${editPixelLimit ~/ 10000} 万像素），请先缩小后再编辑';

/// 获取应用 EXIF 方向后的显示尺寸，原生只读取图片头。
Future<Size> readImageSize(Uint8List bytes) async {
  if (kIsWeb) {
    // Web 的 ImageDescriptor 不提供编码图像的尺寸。
    final codec = await instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        return Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
  final buffer = await ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ImageDescriptor.encoded(buffer);
    try {
      return Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

/// 矩形蒙版：透明区域表示允许重绘，外部保持不透明。
Future<Uint8List> encodeMask(
  int width,
  int height,
  Rect normalized,
) => _encode(width, height, (canvas) {
  final full = Offset.zero & Size(width.toDouble(), height.toDouble());
  canvas.drawRect(
    full,
    Paint()
      ..color = const Color(0xFFFFFFFF)
      ..blendMode = BlendMode.src,
  );
  final area = pixelRect(normalized, width, height);
  canvas.drawRect(
    area,
    Paint()
      ..blendMode = BlendMode.clear
      ..isAntiAlias = false,
  );
});

/// 标注层：同尺寸透明 PNG，仅绘制纯红色自由线。
Future<Uint8List> encodeMarkup(
  int width,
  int height,
  List<List<Offset>> strokes,
) => _encode(width, height, (canvas) {
  const red = Color(0xFFFF0000);
  final stroke = Paint()
    ..color = red
    ..style = PaintingStyle.stroke
    ..strokeWidth = markupStrokeWidth(width)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  final dot = Paint()..color = red..isAntiAlias = true;
  for (final points in strokes) {
    if (points.isEmpty) continue;
    if (points.length == 1) {
      final center = Offset(
        points.first.dx * width,
        points.first.dy * height,
      );
      canvas.drawCircle(center, stroke.strokeWidth / 2, dot);
      continue;
    }
    final path = Path()
      ..moveTo(points.first.dx * width, points.first.dy * height);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx * width, point.dy * height);
    }
    canvas.drawPath(path, stroke);
  }
});

Future<Uint8List> _encode(
  int width,
  int height,
  void Function(Canvas canvas) paint,
) async {
  if (width <= 0 || height <= 0) throw ArgumentError('图片尺寸无效');
  if (width * height > editPixelLimit) {
    throw StateError(oversizedMessage(width, height));
  }
  final recorder = PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ImageByteFormat.png);
      if (data == null) throw StateError('PNG 编码失败');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
