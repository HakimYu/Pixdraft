import 'package:dio/dio.dart';

import 'network_adapter_native.dart'
    if (dart.library.js_interop) 'network_adapter_web.dart';

Dio createNetworkDio([BaseOptions? options]) {
  final dio = Dio(options);
  configureNetworkAdapter(dio);
  return dio;
}
