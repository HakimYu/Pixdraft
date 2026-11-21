import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/image_payload.dart';

void main() {
  test('等长首尾相同的不同图片不误去重，重复终图仍去重', () {
    String image(String color) => base64Encode(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><!--${'x' * 100}--><rect width="1" height="1" fill="$color"/><!--${'y' * 100}--></svg>'));
    final red = image('red'), tan = image('tan');
    expect(red.length, tan.length);
    expect(red.substring(0, 64), tan.substring(0, 64));
    expect(red.substring(red.length - 64), tan.substring(tan.length - 64));
    final collector = ImageCollector(fallbackMime: 'image/svg+xml', seen: {});
    final batch = collector.collect({'data': [{'b64_json': red}, {'b64_json': tan}]});
    expect(batch.images, hasLength(2));
    expect(batch.images[0].bytes, isNot(batch.images[1].bytes));
    expect(collector.collect({'data': [{'b64_json': red}]}).images, isEmpty);
  });
}
