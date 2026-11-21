import 'dart:convert';

class SseEvent {
  const SseEvent(this.event, this.data);

  final String event;
  final String data;

  Map<String, dynamic>? get json {
    try {
      final decoded = jsonDecode(data);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// 增量 SSE 解析：按 LF 分帧、剥离行尾 CR，空行派发事件，多行 data 以 LF 连接。
/// UTF-8 跨字节由 chunked decoder 处理；结束时补齐最后一行与未派发事件。
class SseParser {
  SseParser(this.onEvent, {this.maxBufferChars = 96 * 1024 * 1024});

  // 允许 64 MB 图片的 base64；只限制未完成帧，不限制整个合法事件流。
  final int maxBufferChars;

  /// 返回 true 表示收到终结事件，后续字节不再解析。
  final bool Function(SseEvent event) onEvent;

  final StringBuffer _text = StringBuffer();
  final List<String> _dataLines = [];
  String _pending = '';
  String? _eventName;
  bool _stopped = false;
  bool _sawEvent = false;
  int _dataChars = 0;

  late final ByteConversionSink _sink =
      const Utf8Decoder(allowMalformed: true).startChunkedConversion(StringConversionSink.fromStringSink(_SseStringSink(_accept)));

  bool get stopped => _stopped;
  String get text => _text.toString();

  void add(List<int> bytes) {
    if (_stopped) return;
    _sink.add(bytes);
  }

  void close() {
    if (_stopped) return;
    _sink.close();
    if (_stopped) return;
    if (_pending.isNotEmpty) {
      final line = _pending.endsWith('\r') ? _pending.substring(0, _pending.length - 1) : _pending;
      _pending = '';
      _line(line);
    }
    _dispatch();
  }

  void _accept(String chunk) {
    if (_stopped) return;
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf('\n', start);
      final end = newline < 0 ? chunk.length : newline + 1;
      final fragment = chunk.substring(start, end);
      if (!_sawEvent) {
        if (_text.length + fragment.length > maxBufferChars) throw const FormatException('服务响应过大');
        _text.write(fragment);
      }
      if (_pending.length + fragment.length + _dataChars > maxBufferChars) throw const FormatException('流式事件过大');
      _pending += fragment;
      if (newline >= 0) {
        var line = _pending.substring(0, _pending.length - 1);
        _pending = '';
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        _line(line);
        if (_stopped) return;
      }
      start = end;
    }
  }

  void _line(String line) {
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    if (colon < 0) return;
    final field = line.substring(0, colon);
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      final name = value.trim();
      _eventName = name.isEmpty ? 'message' : name;
    } else if (field == 'data') {
      _dataChars += value.length + 1;
      if (_dataChars > maxBufferChars) throw const FormatException('流式事件过大');
      _dataLines.add(value.trimLeft());
    }
  }

  void _dispatch() {
    if (_dataLines.isEmpty) {
      _eventName = null;
      return;
    }
    _sawEvent = true;
    _text.clear();
    _dataChars = 0;
    final event = _eventName ?? 'message';
    final data = _dataLines.join('\n');
    _dataLines.clear();
    _eventName = null;
    if (onEvent(SseEvent(event, data))) _stopped = true;
  }
}

class _SseStringSink implements StringSink {
  _SseStringSink(this._accept);

  final void Function(String) _accept;

  @override
  void write(Object? object) {
    if (object != null) _accept(object.toString());
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    write(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }
}
