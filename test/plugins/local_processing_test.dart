import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/local_processing.dart';
import 'package:image_gen/plugins/plugin_contract.dart';

Uint8List _solid(int width, int height, {int r = 30, int g = 60, int b = 90}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

int _rgb(img.Pixel pixel) => (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resize', () {
    test('只给宽度且保持比例时按比例缩放', () async {
      final output = await applyLocalImageOperation(_solid(100, 60), 'resize', {'width': 50});
      final decoded = img.decodePng(output)!;
      expect(output.sublist(0, 4), [137, 80, 78, 71]);
      expect((decoded.width, decoded.height), (50, 30));
    });

    test('只给高度且保持比例时按比例缩放', () async {
      final decoded = img.decodePng(await applyLocalImageOperation(_solid(100, 60), 'resize', {'height': 120}))!;
      expect((decoded.width, decoded.height), (200, 120));
    });

    test('同时给宽高且保持比例时不放大超出边界', () async {
      final decoded = img.decodePng(await applyLocalImageOperation(_solid(100, 60), 'resize', {'width': 300, 'height': 300}))!;
      expect(decoded.width <= 300 && decoded.height <= 300, isTrue);
      expect(decoded.width ~/ decoded.height, 100 ~/ 60);
    });

    test('关闭保持比例时使用指定宽高', () async {
      final decoded = img.decodePng(await applyLocalImageOperation(_solid(100, 60), 'resize', {'width': 80, 'height': 90, 'keepAspect': false}))!;
      expect((decoded.width, decoded.height), (80, 90));
    });

    test('缺少宽高时报错', () async {
      await expectLater(applyLocalImageOperation(_solid(10, 10), 'resize', const {}), throwsA(isA<FormatException>()));
    });

    test('关闭保持比例但缺少一边时报错', () async {
      await expectLater(applyLocalImageOperation(_solid(10, 10), 'resize', {'width': 20, 'keepAspect': false}), throwsA(predicate((error) => error is FormatException && error.message.contains('同时填写'))));
    });

    test('超出单边上限时报参数错误', () async {
      await expectLater(applyLocalImageOperation(_solid(10, 10), 'resize', {'width': 9000}), throwsA(predicate((error) => error is FormatException && error.message.contains('8192'))));
    });

    test('输出像素超过总上限时报错', () async {
      final request = applyLocalImageOperation(_solid(2000, 2000), 'resize', {'width': 8192, 'height': 8192, 'keepAspect': false});
      await expectLater(request, throwsA(isA<FormatException>()));
    });
  });

  group('watermark', () {
    test('输出 PNG 且像素发生变化', () async {
      final source = _solid(200, 120);
      final output = await applyLocalImageOperation(source, 'watermark', {'text': '仅供预览'});
      final before = img.decodePng(source)!;
      final after = img.decodePng(output)!;
      expect((after.width, after.height), (before.width, before.height));
      var changed = 0;
      for (var y = 0; y < after.height; y++) {
        for (var x = 0; x < after.width; x++) {
          if (_rgb(before.getPixel(x, y)) != _rgb(after.getPixel(x, y))) changed++;
        }
      }
      expect(changed, greaterThan(0));
      expect(changed, lessThan(after.width * after.height));
    });

    test('不同位置影响不同区域', () async {
      final source = _solid(240, 160);
      final topLeft = img.decodePng(await applyLocalImageOperation(source, 'watermark', {'text': '水印', 'position': '左上'}))!;
      final bottomRight = img.decodePng(await applyLocalImageOperation(source, 'watermark', {'text': '水印', 'position': '右下'}))!;
      expect(_rgb(topLeft.getPixel(10, 10)), isNot(_rgb(bottomRight.getPixel(10, 10))));
      expect(_rgb(topLeft.getPixel(topLeft.width - 10, topLeft.height - 10)), isNot(_rgb(bottomRight.getPixel(topLeft.width - 10, topLeft.height - 10))));
      expect(_rgb(bottomRight.getPixel(10, 10)), _rgb(img.decodePng(source)!.getPixel(10, 10)));
    });

    test('小图不会因水印越界而失败', () async {
      final output = await applyLocalImageOperation(_solid(24, 18), 'watermark', {'text': 'A', 'scale': 0.2});
      expect(img.decodePng(output)!.width, 24);
    });

    test('空文字与非法位置被拒绝', () async {
      await expectLater(applyLocalImageOperation(_solid(20, 20), 'watermark', {'text': '  '}), throwsA(predicate((error) => error is FormatException && error.message.contains('水印文字'))));
      await expectLater(applyLocalImageOperation(_solid(20, 20), 'watermark', {'text': 'A', 'position': '中中'}), throwsA(predicate((error) => error is FormatException && error.message.contains('位置'))));
    });

    test('不透明度越界被拒绝', () async {
      await expectLater(applyLocalImageOperation(_solid(20, 20), 'watermark', {'text': 'A', 'opacity': 2}), throwsA(isA<FormatException>()));
    });
  });

  group('输入校验', () {
    test('空字节被拒绝', () async {
      await expectLater(applyLocalImageOperation(Uint8List(0), 'resize', {'width': 10}), throwsA(predicate((error) => error is FormatException && error.message.contains('为空'))));
    });

    test('未知操作被拒绝', () async {
      await expectLater(applyLocalImageOperation(_solid(10, 10), 'blur', const {}), throwsA(predicate((error) => error is FormatException && error.message.contains('不支持'))));
    });

    test('未知格式被拒绝', () async {
      await expectLater(applyLocalImageOperation(Uint8List.fromList(List.filled(64, 7)), 'resize', {'width': 5}), throwsA(predicate((error) => error is FormatException && error.message.contains('无法识别'))));
    });

    test('SVG 与 GIF 明确不支持', () async {
      await expectLater(applyLocalImageOperation(Uint8List.fromList('<svg width="1" height="1"></svg>'.codeUnits), 'resize', {'width': 5}), throwsA(predicate((error) => error is FormatException && error.message.contains('SVG'))));
      final gif = Uint8List.fromList('GIF89a${'\u0000' * 32}'.codeUnits);
      await expectLater(applyLocalImageOperation(gif, 'resize', {'width': 5}), throwsA(predicate((error) => error is FormatException && error.message.contains('GIF'))));
    });

    test('超过输入上限被拒绝', () async {
      final bytes = Uint8List(localProcessingMaxBytes + 1);
      await expectLater(applyLocalImageOperation(bytes, 'resize', {'width': 5}), throwsA(predicate((error) => error is FormatException && error.message.contains('32 MB'))));
    });
  });

  group('processor', () {
    test('取消后不保存结果', () async {
      final processor = createBuiltinProcessors().firstWhere((item) => item.descriptor.id == 'local.resize');
      var saved = 0;
      final asset = ImageAsset(id: 'a', path: 'assets/a.png', mime: 'image/png', hash: 'a', bytes: 3);
      final context = ProcessingContext(
        readImage: (_) async => _solid(40, 40),
        saveImage: (bytes, mime) async {
          saved++;
          return ImageAsset(id: 'b', path: 'assets/b.png', mime: mime, hash: 'b', bytes: bytes.length);
        },
        isCancelled: () => true,
      );
      await expectLater(processor.process(asset, {'width': 10}, context), throwsA(isA<ProcessingCancelled>()));
      expect(saved, 0);
    });

    test('正常处理经 saveImage 返回 PNG 资产', () async {
      final processor = createBuiltinProcessors().firstWhere((item) => item.descriptor.id == 'local.resize');
      final asset = ImageAsset(id: 'a', path: 'assets/a.png', mime: 'image/png', hash: 'a', bytes: 3);
      String? savedMime;
      final context = ProcessingContext(
        readImage: (_) async => _solid(40, 20),
        saveImage: (bytes, mime) async {
          savedMime = mime;
          return ImageAsset(id: 'b', path: 'assets/b.png', mime: mime, hash: 'b', bytes: bytes.length);
        },
      );
      final result = await processor.process(asset, {'width': 20}, context);
      expect(savedMime, 'image/png');
      expect(result.id, 'b');
    });

    test('内置插件声明可静态校验', () {
      expect(builtinLocalPluginId, 'builtin.local-tools');
      for (final processor in createBuiltinProcessors()) {
        expect(processor.descriptor.pluginId, builtinLocalPluginId);
        expect(processor.descriptor.version, builtinLocalVersion);
        expect(validatePluginFields(processor.descriptor.fields), isNull);
      }
      expect(createBuiltinProcessors().map((item) => item.descriptor.id), containsAll(['local.watermark', 'local.resize']));
      expect(builtinTools().map((tool) => tool.processorId), containsAll(['local.watermark', 'local.resize']));
    });
  });
}