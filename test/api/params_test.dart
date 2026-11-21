import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/params.dart';
import 'package:image_gen/models/models.dart';

ResolvedParams resolve(
  GenerationParams params, {
  ApiProtocol protocol = ApiProtocol.images,
  String model = 'gpt-image-1',
  bool hasInputImages = true,
}) {
  return resolveParams(
    params,
    protocol: protocol,
    imageModel: model,
    hasInputImages: hasInputImages,
  );
}

void main() {
  group('normalizeSize', () {
    test('保留 auto 与无法解析的自定义值', () {
      expect(normalizeSize('auto'), 'auto');
      expect(normalizeSize('  auto  '), 'auto');
      expect(normalizeSize('custom'), 'custom');
    });

    test('已是 16 倍数的常用尺寸保持不变', () {
      expect(normalizeSize('1024x1024'), '1024x1024');
    });

    test('归一化后满足 16 倍数、边长、比例与像素约束', () {
      for (final input in ['1000x1000', '1x1', '9999x100', '300x5000']) {
        final parts = normalizeSize(input).split('x');
        final width = int.parse(parts[0]);
        final height = int.parse(parts[1]);
        expect(width % 16, 0, reason: input);
        expect(height % 16, 0, reason: input);
        expect(width <= 3840 && height <= 3840, isTrue, reason: input);
        final ratio = width > height ? width / height : height / width;
        expect(ratio <= 3, isTrue, reason: input);
        final pixels = width * height;
        expect(pixels >= 655360 && pixels <= 8294400, isTrue, reason: input);
      }
    });
  });

  group('resolveParams', () {
    test('未知模型的 xhigh 回落为 high，已知 2.5 模型保留 xhigh', () {
      expect(
        resolve(const GenerationParams(quality: 'xhigh')).quality,
        'high',
      );
      expect(
        resolve(
          const GenerationParams(quality: 'xhigh'),
          model: 'gpt-image-2.5',
        ).quality,
        'xhigh',
      );
    });

    test('非法值回落，数量夹在 1..10', () {
      final params = resolve(
        const GenerationParams(
          quality: 'ultra',
          background: 'blue',
          count: 99,
          complexity: 'extreme',
        ),
      );
      expect(params.quality, 'auto');
      expect(params.background, 'auto');
      expect(params.count, 10);
      expect(params.complexity, isNull);
    });

    test('GIF 帧数与时长受限，Responses 时长上限 2000ms', () {
      final images = resolve(
        const GenerationParams(format: 'gif', gifFrames: 99, gifDuration: 1),
      );
      expect(images.gifFrames, 16);
      expect(images.gifDuration, 20);
      expect(images.canStream, isFalse);

      final responses = resolve(
        const GenerationParams(format: 'gif', gifDuration: 9000),
        protocol: ApiProtocol.responses,
      );
      expect(responses.gifDuration, 2000);
    });

    test('SVG 单图且不透明，GIF 透明也不支持', () {
      final svg = resolve(
        const GenerationParams(format: 'svg', count: 5, background: 'transparent'),
      );
      expect(svg.count, 1);
      expect(svg.background, 'opaque');
      expect(svg.canStream, isFalse);

      final gif = resolve(
        const GenerationParams(format: 'gif', background: 'transparent'),
      );
      expect(gif.background, 'opaque');
    });

    test('透明 JPEG 改为 PNG，压缩率仅 JPEG/WebP 有效', () {
      final jpeg = resolve(
        const GenerationParams(
          format: 'jpeg',
          background: 'transparent',
          compression: 60,
        ),
      );
      expect(jpeg.format, 'png');
      expect(jpeg.background, 'transparent');
      expect(jpeg.hasCompression, isFalse);

      expect(
        resolve(const GenerationParams(format: 'jpeg')).compression,
        100,
      );
      expect(
        resolve(const GenerationParams(format: 'webp')).hasCompression,
        isTrue,
      );
    });

    test('无输入图时不发送 input_fidelity', () {
      expect(
        resolve(const GenerationParams(), hasInputImages: false).inputFidelity,
        isNull,
      );
      expect(resolve(const GenerationParams()).inputFidelity, 'high');
    });

    test('未知格式与空模型直接报错', () {
      expect(
        () => resolve(const GenerationParams(format: 'tiff')),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => resolve(const GenerationParams(), model: '  '),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
