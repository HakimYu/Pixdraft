import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/api/sse.dart';

void main() {
  test('跨字节 CRLF 与多行 data 正确派发', () {
    final events = <SseEvent>[];
    final parser = SseParser((event) {
      events.add(event);
      return false;
    });

    parser.add(utf8.encode('event: preview\r\ndata: hel'));
    expect(events, isEmpty);
    parser.add(utf8.encode('lo\r\ndata: world\r\n\r\n'));

    expect(events, hasLength(1));
    expect(events.single.event, 'preview');
    expect(events.single.data, 'hello\nworld');
  });

  test('UTF-8 多字节字符跨 chunk 不损坏', () {
    final events = <SseEvent>[];
    final parser = SseParser((event) {
      events.add(event);
      return false;
    });

    final bytes = utf8.encode('data: 猫\n\n');
    parser.add(bytes.sublist(0, 7));
    parser.add(bytes.sublist(7));

    expect(events.single.data, '猫');
  });

  test('注释与未知字段被忽略，默认事件名为 message', () {
    final events = <SseEvent>[];
    final parser = SseParser((event) {
      events.add(event);
      return false;
    });

    parser.add(utf8.encode(': ping\nid: 1\ndata: {"ok":true}\n\n'));

    expect(events.single.event, 'message');
    expect(events.single.json, {'ok': true});
  });

  test('close 派发未以空行结束的尾事件', () {
    final events = <SseEvent>[];
    final parser = SseParser((event) {
      events.add(event);
      return false;
    });

    parser.add(utf8.encode('event: done\ndata: tail'));
    expect(events, isEmpty);
    parser.close();

    expect(events.single.event, 'done');
    expect(events.single.data, 'tail');
  });

  test('回调返回 true 后停止派发', () {
    final events = <SseEvent>[];
    final parser = SseParser((event) {
      events.add(event);
      return true;
    });

    parser.add(utf8.encode('data: first\n\ndata: second\n\n'));
    parser.add(utf8.encode('data: third\n\n'));

    expect(parser.stopped, isTrue);
    expect(events.map((event) => event.data), ['first']);
  });

  test('非 SSE 文本保存在 text 中供 JSON 回退', () {
    final parser = SseParser((event) => false);
    parser.add(utf8.encode('{"data":[]}'));
    parser.close();

    expect(parser.text, '{"data":[]}');
  });
  test('确认流式后丢弃历史文本，累计超过限制的合法事件仍可处理', () {
    var count = 0;
    final parser = SseParser((_) { count++; return false; }, maxBufferChars: 32);
    for (var i = 0; i < 100; i++) {
      parser.add(utf8.encode('data: ok\n\n'));
      expect(parser.text, isEmpty);
    }
    parser.close();
    expect(count, 100);
  });

  test('未结束长行、多行事件和 JSON 回退都有大小限制', () {
    final line = SseParser((_) => false, maxBufferChars: 32);
    expect(() => line.add(utf8.encode('x' * 33)), throwsFormatException);
    final event = SseParser((_) => false, maxBufferChars: 32);
    event.add(utf8.encode('data: ok\n\n'));
    event.add(utf8.encode('data: ${'x' * 15}\n'));
    expect(() => event.add(utf8.encode('data: ${'x' * 15}\n')), throwsFormatException);
    final json = SseParser((_) => false, maxBufferChars: 32);
    expect(() => json.add(utf8.encode('{"data":"${'x' * 32}"}')), throwsFormatException);
  });
}
