import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:dio/dio.dart';
// package:web is already supplied by the Web Dio dependency.
// ignore: depend_on_referenced_packages
import 'package:web/web.dart' as web;

extension type _IterableHeaders(JSObject _) implements JSObject {
  external void forEach(JSFunction callback);
}

void configureNetworkAdapter(Dio dio) {
  dio.httpClientAdapter.close();
  dio.httpClientAdapter = FetchAdapter();
}

class FetchAdapter implements HttpClientAdapter {
  final _active = <web.AbortController>{};
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('网络客户端已关闭');
    final abort = web.AbortController();
    _active.add(abort);
    unawaited(
      cancelFuture?.then((_) {
        if (_active.contains(abort)) abort.abort();
      }),
    );
    void close() {
      _active.remove(abort);
      abort.abort();
    }

    final timers = <Timer>[];
    DioException? timedOut;
    void watch(Duration? timeout, DioException Function(Duration) failure) {
      if (timeout == null || timeout <= Duration.zero) return;
      timers.add(
        Timer(timeout, () {
          timedOut ??= failure(timeout);
          close();
        }),
      );
    }

    try {
      // Fetch buffered uploads work across browsers without request duplex.
      final bytes = requestStream == null
          ? null
          : await requestStream.fold(
              BytesBuilder(copy: false),
              (buffer, chunk) => buffer..add(chunk),
            );
      if (abort.signal.aborted) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: null,
        );
      }
      final headers = web.Headers();
      for (final entry in options.headers.entries) {
        if (entry.value == null || entry.key.toLowerCase() == 'content-length') {
          continue;
        }
        final value = entry.value;
        headers.set(
          entry.key,
          value is Iterable ? value.join(', ') : value.toString(),
        );
      }
      // Fetch cannot distinguish upload, connection and response headers.
      watch(
        options.connectTimeout,
        (timeout) => DioException.connectionTimeout(
          timeout: timeout,
          requestOptions: options,
        ),
      );
      watch(
        options.sendTimeout,
        (timeout) =>
            DioException.sendTimeout(timeout: timeout, requestOptions: options),
      );
      watch(
        options.receiveTimeout,
        (timeout) => DioException.receiveTimeout(
          timeout: timeout,
          requestOptions: options,
        ),
      );
      final response = await web.window
          .fetch(
            options.uri.toString().toJS,
            web.RequestInit(
              method: options.method,
              headers: headers,
              body: bytes?.takeBytes().toJS,
              mode: 'cors',
              credentials: 'omit',
              redirect: 'manual',
              cache: 'no-store',
              referrerPolicy: 'no-referrer',
              signal: abort.signal,
            ),
          )
          .toDart;
      // Browsers hide the redirect destination and status. Report a redirect
      // without a Location so shared download code cannot follow it either.
      if (response.type == 'opaqueredirect') {
        close();
        return ResponseBody.fromString('', 302, isRedirect: true);
      }
      final responseHeaders = <String, List<String>>{};
      _IterableHeaders(response.headers).forEach(
        ((JSString value, JSString name, JSAny? _) {
          responseHeaders[name.toDart] = [value.toDart];
        }).toJS,
      );
      final body = response.body;
      if (body == null) _active.remove(abort);
      return ResponseBody(
        body == null ? const Stream.empty() : _read(body, close),
        response.status,
        headers: responseHeaders,
        onClose: close,
      );
    } on DioException {
      close();
      rethrow;
    } catch (_) {
      close();
      throw timedOut ??
          DioException.connectionError(
            requestOptions: options,
            reason: 'Web 请求失败，请检查网络和服务的 CORS 配置',
          );
    } finally {
      for (final timer in timers) {
        timer.cancel();
      }
    }
  }

  Stream<Uint8List> _read(web.ReadableStream body, void Function() close) {
    final reader = web.ReadableStreamDefaultReader(body);
    late final StreamController<Uint8List> stream;
    var reading = false;
    Future<void> pump() async {
      if (reading) return;
      reading = true;
      try {
        while (stream.hasListener && !stream.isPaused) {
          final chunk = await reader.read().toDart;
          if (!stream.hasListener) return;
          if (chunk.done) {
            unawaited(stream.close());
            return;
          }
          stream.add((chunk.value as JSUint8Array).toDart);
        }
      } catch (error, stack) {
        if (stream.hasListener) stream.addError(error, stack);
        unawaited(stream.close());
      } finally {
        reading = false;
        if (stream.isClosed || !stream.hasListener) {
          reader.releaseLock();
          close();
        }
      }
    }

    stream = StreamController<Uint8List>(
      onListen: pump,
      onResume: pump,
      onCancel: () {
        // Wake an outstanding JS read on timeout or subscription cancellation.
        if (!reading && !stream.isClosed) reader.releaseLock();
        close();
      },
    );
    return stream.stream;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    if (force) {
      for (final abort in _active) {
        abort.abort();
      }
      _active.clear();
    }
  }
}
