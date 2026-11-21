import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/editor/editor_export.dart';

Future<Image> _decode(Uint8List png) async {
  final codec = await instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<Uint8List> _pixelsOf(Uint8List png) async {
  final image = await _decode(png);
  try {
    final data = await image.toByteData(format: ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

int _alpha(Uint8List rgba, int width, int x, int y) =>
    rgba[(y * width + x) * 4 + 3];

List<int> _rgbaAt(Uint8List rgba, int width, int x, int y) {
  final index = (y * width + x) * 4;
  return rgba.sublist(index, index + 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('蒙版保持源图尺寸，选区透明、外部不透明', () async {
    final bytes = await encodeMask(
      100,
      80,
      const Rect.fromLTRB(.25, .25, .75, .75),
    );
    final image = await _decode(bytes);
    expect(image.width, 100);
    expect(image.height, 80);
    image.dispose();

    final rgba = await _pixelsOf(bytes);
    expect(_rgbaAt(rgba, 100, 0, 0), [255, 255, 255, 255]);
    expect(_rgbaAt(rgba, 100, 99, 79), [255, 255, 255, 255]);
    // 选区内部必须完全透明，外部紧邻像素保持不透明（非抗锯齿）。
    expect(_alpha(rgba, 100, 50, 40), 0);
    expect(_alpha(rgba, 100, 24, 40), 255);
    expect(_alpha(rgba, 100, 25, 40), 0);
  });

  test('蒙版覆盖整张图时全部透明', () async {
    final bytes = await encodeMask(8, 6, const Rect.fromLTRB(0, 0, 1, 1));
    final rgba = await _pixelsOf(bytes);
    for (var i = 3; i < rgba.length; i += 4) {
      expect(rgba[i], 0);
    }
  });

  test('标注为透明背景，仅绘制纯红色线条', () async {
    final bytes = await encodeMarkup(
      60,
      40,
      [
        [
          const Offset(.1, .5),
          const Offset(.9, .5),
        ],
      ],
    );
    final image = await _decode(bytes);
    expect(image.width, 60);
    expect(image.height, 40);
    image.dispose();

    final rgba = await _pixelsOf(bytes);
    expect(_alpha(rgba, 60, 0, 0), 0);
    expect(_alpha(rgba, 60, 59, 39), 0);
    final line = _rgbaAt(rgba, 60, 30, 20);
    expect(line[0], greaterThan(240));
    expect(line[1], lessThan(10));
    expect(line[2], lessThan(10));
    expect(line[3], greaterThan(240));
  });

  test('单点标注绘制为红色圆点', () async {
    final bytes = await encodeMarkup(20, 20, [
      [const Offset(.5, .5)],
    ]);
    final rgba = await _pixelsOf(bytes);
    final center = _rgbaAt(rgba, 20, 10, 10);
    expect(center[0], greaterThan(150));
    expect(center[3], greaterThan(150));
    expect(_alpha(rgba, 20, 0, 0), 0);
  });

  test('超过像素上限时编码明确失败，不静默降质', () async {
    expect(
      encodeMask(4001, 4000, const Rect.fromLTRB(0, 0, .5, .5)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('图片过大'),
        ),
      ),
    );
    expect(
      encodeMask(0, 10, const Rect.fromLTRB(0, 0, 1, 1)),
      throwsArgumentError,
    );
  });

  test('readImageSize 返回真实像素尺寸', () async {
    final bytes = await encodeMask(33, 17, const Rect.fromLTRB(.2, .2, .6, .6));
    expect(await readImageSize(bytes), const Size(33, 17));
  });

  test('EXIF 旋转 JPEG 使用解码朝向的尺寸，导出坐标与显示一致', () async {
    final bytes = await File(
      'test/features/editor/fixtures/exif_orientation_6.jpg',
    ).readAsBytes();
    // fixture 编码像素 6×4（左半红、右半蓝），EXIF Orientation=6 表示显示时顺时针旋转 90°。
    final size = await readImageSize(bytes);
    final image = await _decode(bytes);
    try {
      expect(size, Size(image.width.toDouble(), image.height.toDouble()));
      expect(size, const Size(4, 6));
      final data = await image.toByteData(format: ImageByteFormat.rawRgba);
      final rgba = data!.buffer.asUint8List();
      // 旋转后上方来自原图左侧（红），下方来自右侧（蓝）。
      final top = _rgbaAt(rgba, 4, 1, 1);
      final bottom = _rgbaAt(rgba, 4, 1, 4);
      expect(top[0], greaterThan(200));
      expect(top[2], lessThan(80));
      expect(bottom[2], greaterThan(200));
      expect(bottom[0], lessThan(80));
    } finally {
      image.dispose();
    }
  });

  test('仅 PNG/JPEG/WebP 可编辑，GIF 与 SVG 给出明确提示', () {
    expect(editableMimes, {'image/png', 'image/jpeg', 'image/webp'});
    expect(unsupportedMessage('image/gif'), contains('GIF'));
    expect(unsupportedMessage('image/svg+xml'), contains('SVG'));
  });
}
