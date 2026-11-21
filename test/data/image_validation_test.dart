import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/image_validation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
  int uint32(int offset) => (png[offset] << 24) | (png[offset + 1] << 16) | (png[offset + 2] << 8) | png[offset + 3];

  test('有效 PNG 返回头部声明的宽高', () async {
    expect(ascii.decode(png.sublist(12, 16)), 'IHDR');
    final size = await validateImage(png, 'image/png');
    expect(size.width, uint32(16));
    expect(size.height, uint32(20));
    expect(size.width, greaterThan(0));
  });

  test('内容与声明的 MIME 不符时拒绝', () async {
    await expectLater(validateImage(png, 'image/jpeg'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('格式不符'))));
    await expectLater(validateImage(utf8.encode('not an image'), 'image/gif'), throwsA(isA<FormatException>()));
    await expectLater(validateImage(Uint8List(0), 'image/png'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('格式或大小'))));
  });

  test('损坏的 PNG 无法解码', () async {
    final corrupted = Uint8List.fromList([...png.sublist(0, 8), ...List.filled(32, 0)]);
    await expectLater(validateImage(corrupted, 'image/png'), throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('无法解码'))));
  });

  test('有效内联 SVG 通过且没有位图尺寸', () async {
    final svg = utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="#f00"/></svg>');
    final size = await validateImage(svg, 'image/svg+xml');
    expect(size.width, isNull);
    expect(size.height, isNull);
  });

  test('拒绝 SVG 外部资源和脚本', () async {
    final rejected = <String>[
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image href="https://evil.test/a.png"/></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image xlink:href="//evil.test/a.png"/></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect fill="url(#x)"/></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>',
      '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><foreignObject/></svg>',
      '<!DOCTYPE svg [<!ENTITY x "boom">]><svg xmlns="http://www.w3.org/2000/svg"><text>&x;</text></svg>',
      '<html><body>hello</body></html>',
    ];
    for (final svg in rejected) {
      await expectLater(validateImage(utf8.encode(svg), 'image/svg+xml'), throwsA(isA<FormatException>()), reason: svg);
    }
  });
}
