import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/input_preparation.dart';


const _gif1x1Base64 =
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

Future<Uint8List> _renderPng(
  int width,
  int height,
  void Function(ui.Canvas canvas) paint,
) async {
  final recorder = ui.PictureRecorder();
  paint(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<({int width, int height})> _decodeSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return (width: descriptor.width, height: descriptor.height);
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

Future<Uint8List> _decodeRgba(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('超过阈值：按最长边缩小并编码为 PNG', () async {
    final original = await _renderPng(3000, 100, (canvas) {
      for (var i = 0; i < 300; i++) {
        canvas.drawRect(
          ui.Rect.fromLTWH(i * 10.0, 0, 10, 100),
          ui.Paint()..color = ui.Color(0xFF000000 | (i * 7919 % 0xFFFFFF)),
        );
      }
    });

    final result = await prepareInlineImage(
      original,
      'image/png',
      thresholdBytes: original.length - 1,
      maxEdge: 2048,
    );

    expect(result, isNotNull);
    expect(result!.mime, 'image/png');
    expect(result.bytes, isNot(same(original)));
    final size = await _decodeSize(result.bytes);
    expect(size.width, 2048);
    expect(size.height, closeTo(68, 1));
  });

  test('小于阈值时保留原 bytes', () async {
    final original = await _renderPng(32, 32, (canvas) {
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 32, 32),
        ui.Paint()..color = const ui.Color(0xFF3366CC),
      );
    });

    final result = await prepareInlineImage(original, 'image/PNG');

    expect(result, isNull);
  });

  test('PNG 透明通道在压缩后保留', () async {
    final random = math.Random(7);
    final original = await _renderPng(1024, 1024, (canvas) {
      for (var x = 512; x < 1024; x += 8) {
        for (var y = 0; y < 1024; y += 8) {
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 8, 8),
            ui.Paint()..color = ui.Color(0xFF000000 | random.nextInt(0xFFFFFF)),
          );
        }
      }
    });

    final result = await prepareInlineImage(
      original,
      'image/png',
      thresholdBytes: original.length - 1,
      maxEdge: 64,
    );

    expect(result, isNotNull);
    final rgba = await _decodeRgba(result!.bytes);
    final alphas = [for (var i = 3; i < rgba.length; i += 4) rgba[i]];
    expect(alphas, contains(0));
    expect(alphas, contains(255));
  });

  test('JPEG 的 EXIF 方向在压缩后保留', () async {
    final original = await File('test/features/editor/fixtures/exif_orientation_6.jpg').readAsBytes();

    final result = await prepareInlineImage(
      original,
      'image/jpeg',
      thresholdBytes: original.length - 1,
      maxEdge: 3,
    );

    expect(result, isNotNull);
    expect(result!.mime, 'image/png');
    final size = await _decodeSize(result.bytes);
    expect(size.width, 2);
    expect(size.height, 3);
  });

  test('GIF 保持原始，避免丢失动画', () async {
    final gif = Uint8List(800 * 1024);
    final head = base64Decode(_gif1x1Base64);
    gif.setRange(0, head.length, head);

    expect(await prepareInlineImage(gif, 'image/gif'), isNull);
    expect(
      await prepareInlineImage(gif, 'image/gif', thresholdBytes: 0),
      isNull,
    );
  });

  test('像素数超过上限时明确抛出 FormatException', () async {
    final original = await _renderPng(80, 80, (canvas) {
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 80, 80),
        ui.Paint()..color = const ui.Color(0xFF00FF00),
      );
    });

    await expectLater(
      prepareInlineImage(
        original,
        'image/png',
        thresholdBytes: 0,
        maxPixels: 100,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('大文件无法解码时明确抛出 FormatException', () async {
    final junk = Uint8List(800 * 1024);

    await expectLater(
      prepareInlineImage(junk, 'image/png'),
      throwsA(isA<FormatException>()),
    );
  });
}
