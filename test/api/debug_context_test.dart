import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/debug_context.dart';
import 'package:image_gen/api/params.dart';
import 'package:image_gen/models/models.dart';

import 'support.dart';

void main() {
  test('隐藏 Bearer、data URL 与长 base64', () {
    final dataUrl = 'data:image/png;base64,${'A' * 800}';
    final text = summarizeLogString('token Bearer abc.def-123 图片 $dataUrl 结尾');
    expect(text, isNot(contains('abc.def-123')));
    expect(text, contains('Bearer [已隐藏]'));
    expect(text, isNot(contains('A' * 40)));
    expect(text, contains('[数据图片 mime=image/png'));
    expect(text, contains('内容已隐藏]'));
    expect(summarizeLogString('A' * 700), '[base64 长度 700 已隐藏]');
  });

  test('超长文本按字符截断并标注长度', () {
    final text = summarizeLogString('字' * 2000, limit: 100);
    expect(text.length, lessThan(140));
    expect(text, contains('…（已截断 1900 字符）'));
  });

  test('结构化值限制深度、数量和敏感键', () {
    final value = sanitizeLogValue({
      'Authorization': 'Bearer key',
      'api-key': 'key',
      'token': 'token',
      'nested': {
        'a': {
          'b': {
            'c': {
              'd': {'e': {'f': 'too-deep'}},
            },
          },
        },
      },
      'items': List.generate(15, (index) => index),
    }) as Map<String, Object?>;
    expect(value['Authorization'], '[已隐藏]');
    expect(value['api-key'], '[已隐藏]');
    expect(value['token'], '[已隐藏]');
    expect((value['items'] as List).last, '[+5 项已省略]');
    expect('$value', contains('[已达到最大深度]'));
    expect('$value', isNot(contains('too-deep')));

    final wide = sanitizeLogValue({for (var i = 0; i < 40; i++) 'k$i': i}) as Map<String, Object?>;
    expect(wide.length, 31);
    expect(wide['__已省略键'], 10);
  });

  test('响应体 JSON 结构化脱敏，非 JSON 按文本处理', () {
    final json = summarizeResponseBody('{"error":{"message":"失败","api_key":"hidden-by-redaction","image":"data:image/png;base64,${'B' * 700}"}}');
    expect(json, contains('[已隐藏]'));
    expect(json, isNot(contains('hidden-by-redaction')));
    expect(json, isNot(contains('B' * 40)));
    expect(summarizeResponseBody('Bad gateway ' * 300), contains('…（已截断'));
    expect(summarizeResponseBody('   '), '（空响应）');
  });

  test('地址脱敏保留协议、主机和路径', () {
    expect(
      summarizeUrl(Uri.parse('https://user:pw@api.example.test:8443/v1/images?token=abc#frag')),
      'https://api.example.test:8443/v1/images?…已隐藏#…已隐藏',
    );
    expect(summarizeUrlString('https://cdn.example.test/out.png?sig=secret'), 'https://cdn.example.test/out.png?…已隐藏');
    expect(summarizeUrlString('not a url'), '[地址已隐藏]');
    expect(summarizeUrlString('  '), '');
  });

  test('诊断信息包含协议、模型、参数、尝试与说明', () {
    final input = testInput(provider: testProvider(transport: TransportMode.stream), prompt: '画一只猫');
    final context = ErrorContext(input, startedAt: DateTime.now().subtract(const Duration(seconds: 3)))
      ..model = 'gpt-image-1'
      ..params = resolveParams(const GenerationParams(), protocol: ApiProtocol.images, imageModel: 'gpt-image-1', hasInputImages: false);
    context.setAssets(references: [(mime: 'image/png', bytes: 2048, inline: true)], mask: (mime: 'image/png', bytes: 1024));
    context.record(
      url: Uri.parse('https://api.example.test/v1/images/generations?token=secret'),
      elapsed: const Duration(milliseconds: 1500),
      transport: 'stream',
      body: 'json',
      compat: true,
      status: 500,
      requestId: 'req-1',
      response: '{"error":{"message":"boom"}}',
    );
    context.note('流式传输失败，已回退 JSON 传输重试');
    context.note('流式传输失败，已回退 JSON 传输重试');
    context.note('Bearer secret-token');

    final text = context.render();
    expect(text, startsWith('诊断信息'));
    expect(text, contains('协议：images；请求模式：stream；模型：gpt-image-1；超时：900 秒'));
    expect(text, contains('参数：size=auto，quality=auto，format=png，count=1'));
    expect(text, contains('提示词：画一只猫（共 4 字符）'));
    expect(text, contains('参考图 1 张：image/png 2.0 KB（已压缩内联）'));
    expect(text, contains('蒙版：image/png 1.0 KB'));
    expect(
      text,
      contains('POST https://api.example.test/v1/images/generations?…已隐藏（stream/json，兼容参数）→ HTTP 500，request_id: req-1，用时 1.5 秒'),
    );
    expect(text, contains('  响应：'));
    expect(text, contains('说明：流式传输失败，已回退 JSON 传输重试；Bearer [已隐藏]'));
    expect(text, isNot(contains('secret')));
  });

  test('尝试次数有上限并提示省略', () {
    final context = ErrorContext(testInput(provider: testProvider(), prompt: 'x'));
    for (var i = 0; i < 14; i++) {
      context.record(url: Uri.parse('https://api.example.test/v1/images/generations'), elapsed: Duration.zero, status: 500);
    }
    final text = context.render();
    expect('请求：'.allMatches(text), hasLength(1));
    expect(text, contains('…其余 2 次尝试已省略'));
    expect(RegExp(r'^\d+\. POST', multiLine: true).allMatches(text), hasLength(12));
  });
  test('Responses 快照同时保留文本模型与图片模型', () {
    final input = testInput(provider: testProvider(protocol: ApiProtocol.responses), prompt: '画一只猫');
    final context = ErrorContext(input)..model = input.provider.toolModel;
    expect(context.render(), contains('Responses 模型：${input.provider.responseModel}'));
    expect(context.render(), contains('模型：${input.provider.toolModel}'));
  });
}
