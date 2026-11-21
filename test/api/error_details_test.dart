import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/error_details.dart';
import 'package:image_gen/api/api_failure.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:image_gen/features/gallery/error_details.dart';

void main() {
  test('解析中转错误、错误码、HTTP 与脱敏详情', () {
    final text = describeApiError({'error': {'details': {'upstream_response': '{"error":{"message":"quota exhausted","code":"insufficient_quota","param":"model"}}'}, 'api_key': 'custom-secret'}}, status: 429);
    final saved = safeError(ApiFailure(text, status: 429), secret: 'custom-secret');
    expect(saved, startsWith('quota exhausted'));
    expect(saved, contains('code：insufficient_quota'));
    expect(saved, contains('param：model'));
    expect(saved, contains('HTTP 状态码：429'));
    expect(saved, contains('额度不足'));
    expect(saved, contains('响应详情：'));
    expect(saved, isNot(contains('custom-secret')));
  });
  test('兼容 detail 数组、未知错误码和非 JSON 响应', () {
    expect(describeApiError({'detail': [{'msg': 'bad width'}, {'msg': 'bad height'}]}), startsWith('bad width；bad height'));
    expect(describeApiError({'error': {'code': 'vendor_specific', 'message': 'failed'}}), contains('code：vendor_specific'));
    expect(describeApiError('Bad gateway', status: 502), contains('供应商服务异常'));
    expect(safeError(ApiFailure(describeApiError({'message': 'failed', 'token': 'private-token'}))), isNot(contains('private-token')));
  });
  testWidgets('可以打开和选择错误详情文本', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ErrorDetails(message: '失败\ncode：invalid_api_key'))));
    await tester.tap(find.text('查看错误信息'));
    await tester.pumpAndSettle();
    expect(find.text('错误详情'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('失败\ncode：invalid_api_key'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('一键复制完整报错并给出反馈', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    const message = '失败\ncode：invalid_api_key\n\n诊断信息\n请求：\n1. POST https://api.example.test/v1/images/generations';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ErrorDetails(message: message))));

    await tester.tap(find.text('复制报错'));
    await tester.pump();
    expect(copied, message);
    expect(find.text('完整报错已复制'), findsOneWidget);

    await tester.tap(find.text('查看错误信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制完整报错'));
    await tester.pumpAndSettle();
    expect(copied, message);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('完整报错已复制'), findsOneWidget);
  });
  testWidgets('剪贴板写入失败时显示提示', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') throw PlatformException(code: 'unavailable');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ErrorDetails(message: '失败'))));
    await tester.tap(find.text('复制报错'));
    await tester.pumpAndSettle();
    expect(find.text('复制报错失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
