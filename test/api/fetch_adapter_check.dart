// dart compile js test/api/fetch_adapter_check.dart -o /tmp/fetch_adapter_check.js
// node -r ./test/api/fetch_adapter_mock.cjs /tmp/fetch_adapter_check.js
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:image_gen/api/network_dio.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final dio = createNetworkDio();
  const origin = 'https://mock.invalid';
  final token = CancelToken();
  final response = await dio.post<ResponseBody>(
    '$origin/stream',
    data: {'prompt': 'mock'},
    cancelToken: token,
    options: Options(
      headers: {'Authorization': 'Bearer mock'},
      responseType: ResponseType.stream,
    ),
  );
  await for (final chunk in response.data!.stream) {
    check(
      utf8.decode(chunk) == 'data: preview\n\n',
      'SSE preview was buffered',
    );
    token.cancel();
    break;
  }
  final redirected = await dio.get<String>(
    '$origin/redirect',
    options: Options(validateStatus: (_) => true),
  );
  check(
    redirected.isRedirect && redirected.headers.value('location') == null,
    'opaque redirects must be reported without a destination',
  );
  try {
    await dio.get<void>(
      '$origin/timeout',
      options: Options(receiveTimeout: const Duration(milliseconds: 25)),
    );
    throw StateError('Expected receive timeout');
  } on DioException catch (error) {
    check(error.type == DioExceptionType.receiveTimeout, 'Wrong timeout error');
  }
  dio.close(force: true);
}
