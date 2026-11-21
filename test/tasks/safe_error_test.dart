import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/tasks/task_runner.dart';

void main() {
  test('错误持久化前移除供应商回显的密钥和签名链接', () {
    final error = FormatException('request failed custom-token Bearer other-token https://example.com/image?secret=1 sk-private');
    final message = safeError(error, secret: 'custom-token');
    expect(message, isNot(contains('custom-token')));
    expect(message, isNot(contains('other-token')));
    expect(message, isNot(contains('secret=1')));
    expect(message, isNot(contains('sk-private')));
    expect(safeError(FormatException('错误' * 300)).length, 500);
  });
  test('保留地址主机与路径，只隐藏查询串和片段', () {
    final message = safeError(FormatException('failed https://api.example.test/v1/images?token=sign-me#frag'));
    expect(message, contains('https://api.example.test/v1/images?…已隐藏#…已隐藏'));
    expect(message, isNot(contains('sign-me')));
    expect(safeError(FormatException('failed at not-a-url')), 'failed at not-a-url');
  });
  test('诊断信息与二进制数据入库前脱敏且不被截断', () {
    final message = safeError(FormatException('失败\n\n诊断信息\n说明：${'说明' * 2000}'));
    expect(message.length, greaterThan(1000));
    expect(message, contains('诊断信息'));
    expect(message, isNot(contains('…（详情已截断）')));

    final binary = safeError(FormatException('失败 data:image/png;base64,${'A' * 800} ${'B' * 700}'));
    expect(binary, contains('[数据图片 mime=image/png'));
    expect(binary, contains('[base64 长度 700 已隐藏]'));
    expect(binary, isNot(contains('A' * 40)));
    expect(binary, isNot(contains('B' * 40)));
  });
  test('不含详情时仍截断到 500 字符', () {
    final message = safeError(FormatException('错误' * 300));
    expect(message.length, 500);
    expect(message, isNot(contains('详情已截断')));
  });
}
