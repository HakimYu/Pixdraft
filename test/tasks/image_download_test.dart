import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/tasks/image_download.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return respond(options);
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  test('跨域相对重定向逐跳检查且不发送 Authorization', () async {
    final adapter = _Adapter((request) => request.uri.host == 'first.test'
        ? ResponseBody.fromString('', 302, headers: {'location': ['https://second.test/image']})
        : ResponseBody(Stream.value(Uint8List.fromList([1, 2, 3])), 200));
    final dio = Dio(BaseOptions(headers: {'Authorization': 'Bearer test-key'}))..httpClientAdapter = adapter;
    expect(await downloadImage('https://first.test/start', downloader: dio), [1, 2, 3]);
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(request.headers.entries.where((e) => e.key.toLowerCase() == 'authorization' && e.value != null), isEmpty);
      expect(request.followRedirects, isFalse);
    }
    dio.close();
  });

  test('重定向到 file 或带用户凭据地址时不发送第二次请求', () async {
    for (final target in ['file:///etc/passwd', 'https://user:password@second.test/image']) {
      final adapter = _Adapter((_) => ResponseBody.fromString('', 302, headers: {'location': [target]}));
      final dio = Dio()..httpClientAdapter = adapter;
      await expectLater(downloadImage('https://first.test/image', downloader: dio), throwsFormatException);
      expect(adapter.requests, hasLength(1));
      dio.close();
    }
  });

  test('循环重定向最多发送六次请求', () async {
    final adapter = _Adapter((_) => ResponseBody.fromString('', 302, headers: {'location': ['/again']}));
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(downloadImage('https://first.test/image', downloader: dio), throwsFormatException);
    expect(adapter.requests, hasLength(6));
    dio.close();
  });

  test('超过 64 MiB 的流中止且不返回截断结果', () async {
    final chunk = Uint8List(1024 * 1024);
    final adapter = _Adapter((_) => ResponseBody(Stream.fromIterable(List.filled(65, chunk)), 200));
    final dio = Dio()..httpClientAdapter = adapter;
    await expectLater(downloadImage('https://first.test/image', downloader: dio), throwsFormatException);
    dio.close();
  });
}
