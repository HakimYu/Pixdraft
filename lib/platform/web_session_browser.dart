import 'dart:async';
import 'dart:js_interop';

@JS('navigator.locks')
external _LockManager? get _locks;

extension type _LockManager(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    _LockOptions options,
    JSFunction callback,
  );
}

extension type _LockOptions._(JSObject _) implements JSObject {
  external factory _LockOptions({bool ifAvailable});
}

bool _held = false;

Future<String?> acquireWebSession() async {
  if (_held) return null;
  final locks = _locks;
  if (locks == null) return '请在支持 Web Locks 的浏览器中通过 HTTPS 或 localhost 打开工作台';

  final acquired = Completer<bool>();
  try {
    unawaited(locks.request(
      'image-gen-studio',
      _LockOptions(ifAvailable: true),
      ((JSObject? lock) {
        _held = lock != null;
        acquired.complete(_held);
        // 页面关闭时浏览器释放锁；只有持锁页面可以恢复或发送任务。
        return _held ? Completer<JSAny?>().future.toJS : null;
      }).toJS,
    ).toDart.then<void>((_) {}, onError: acquired.completeError));
    return await acquired.future ? null : '工作台已在另一个标签页打开，请关闭那个标签页后重试';
  } catch (_) {
    return '无法取得工作台的浏览器访问权限，请检查浏览器设置后重试';
  }
}
