import 'dart:typed_data';

import 'package:dio/dio.dart';

Future<Uint8List> downloadImage(String url, {required Dio downloader, CancelToken? token}) async {
  var uri = Uri.parse(url);
  for (var redirects = 0; redirects <= 5; redirects++) {
    if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) throw const FormatException('图片下载地址无效');
    final response = await downloader.getUri<ResponseBody>(uri, cancelToken: token, options: Options(responseType: ResponseType.stream, followRedirects: false, headers: {'Authorization': null}, validateStatus: (s) => s != null && s >= 200 && s < 400));
    if (response.statusCode! >= 300) {
      final location = response.headers.value('location');
      await response.data!.stream.drain<void>();
      if (location == null) throw const FormatException('下载重定向缺少地址');
      uri = uri.resolve(location);
      continue;
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (buffer.length + chunk.length > 64 * 1024 * 1024) throw const FormatException('图片超过 64 MB');
      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }
  throw const FormatException('图片下载重定向过多');
}
