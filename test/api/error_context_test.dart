import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/api_failure.dart';
import 'package:image_gen/api/debug_context.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/tasks/task_runner.dart';

import 'support.dart';

void main() {
  setUpAll(setUpApiFiles);
  tearDownAll(tearDownApiFiles);

  test('HTTP 错误附带脱敏诊断且只请求一次', () async {
    final secretUrl = 'https://cdn.example.test/out.png?sign=abc123';
    final adapter = FakeAdapter(
      (options, cancelFuture) async =>
          errorBody(500, 'upstream failed $secretUrl ${'A' * 900}'),
    );
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(provider: testProvider(transport: TransportMode.auto), prompt: '一只猫'),
        'key',
      ),
    );

    expect(adapter.requests, hasLength(1));
    final error = result.error as ApiFailure;
    expect(error.status, 500);
    // 诊断信息只追加在末尾，重试判断读取的第一行保持原样。
    expect(error.message.split('\n').first, 'upstream failed $secretUrl ${'A' * 900}');
    expect(error.message, contains('\n\n诊断信息\n'));
    expect(error.message, contains('协议：images；请求模式：auto；模型：gpt-image-1；超时：900 秒'));
    expect(error.message, contains('请求：'));
    expect(error.message, contains('POST https://api.example.test/v1/images/generations'));
    expect(error.message, contains('HTTP 500'));

    final saved = safeError(error);
    expect(saved, contains('https://cdn.example.test/out.png?…已隐藏'));
    expect(saved, isNot(contains('sign=abc123')));
    expect(saved, isNot(contains('A' * 60)));
    expect(saved, contains('[base64 长度 900 已隐藏]'));
  });

  test('流式错误事件附带上下文与说明', () async {
    final adapter = FakeAdapter(
      (options, cancelFuture) async => sseBody(
        'event: error\n'
        'data: {"type":"error","error":{"message":"failed https://cdn.example.test/a.png?sig=xyz","code":"server_error"}}\n\n',
      ),
    );
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(provider: testProvider(transport: TransportMode.stream), prompt: '一只猫'),
        'key',
      ),
    );

    expect(adapter.requests, hasLength(1));
    final error = result.error as ApiFailure;
    expect(error.message, contains('诊断信息'));
    expect(error.message, contains('（stream/json'));
    expect(error.message, contains('说明：'));
    expect(error.message, contains('流式响应返回错误事件（已收到'));
    expect(safeError(error), isNot(contains('sig=xyz')));
  });

  test('流式缺少完整结果时附带上下文', () async {
    final adapter = FakeAdapter(
      (options, cancelFuture) async => sseBody('data: {"type":"response.created"}\n\n'),
    );
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(provider: testProvider(transport: TransportMode.stream), prompt: '一只猫'),
        'key',
      ),
    );

    expect(result.error, isA<FormatException>());
    final message = (result.error as FormatException).message;
    expect(message, startsWith('流式接口已返回事件，但未收到完整结果。'));
    expect(message, contains('诊断信息'));
    expect(message, contains('流式响应结束但未收到完整图片'));
  });

  test('诊断信息不改变保守重试：400 不支持流式仅回退一次', () async {
    final adapter = FakeAdapter(
      (options, cancelFuture) async => errorBody(400, 'streaming is not supported for this model'),
    );
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(provider: testProvider(transport: TransportMode.auto), prompt: '一只猫'),
        'key',
      ),
    );

    expect(adapter.requests, hasLength(2));
    final error = result.error as ApiFailure;
    expect(error.status, 400);
    expect(error.message, contains('说明：流式传输失败，已回退 JSON 传输重试'));
    expect(RegExp(r'^\d+\. POST', multiLine: true).allMatches(error.message), hasLength(2));
  });

  test('图片与内联输入不会以 base64 形式写入诊断', () async {
    final adapter = FakeAdapter(
      (options, cancelFuture) async => errorBody(422, 'bad image'),
    );
    final client = clientFor(adapter);
    final result = await drain(
      client.generate(
        testInput(
          provider: testProvider(protocol: ApiProtocol.responses, transport: TransportMode.json),
          prompt: '重绘',
          references: [referenceAsset()],
          mask: maskAsset(),
        ),
        'key',
      ),
    );

    expect(result.error, isA<ApiFailure>());
    final message = (result.error as FormatException).message;
    expect(message, contains('参考图 1 张：image/png 5 B'));
    expect(message, contains('蒙版：image/png 5 B'));
    expect(message, contains('响应输入方式：内联图片'));
    expect(hideBinaryPayloads(message), message);
  });
}
