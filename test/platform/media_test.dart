import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/platform/media.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Picker extends FilePickerPlatform {
  int calls = 0;
  Uint8List? savedBytes;
  String? savedMime, savedName;
  Uri? result = Uri.parse('content://documents/image');
  Object? error;

  @override
  Future<Uri?> saveFile({required String fileName, required Uint8List bytes, required String mimeType, String? dialogTitle, String? initialDirectory, Function(FilePickerStatus)? onFileSaving, WindowsOptions windowsOptions = const WindowsOptions(), LinuxOptions linuxOptions = const LinuxOptions(), WebOptions webOptions = const WebOptions()}) async {
    calls++;
    savedBytes = bytes;
    savedMime = mimeType;
    savedName = fileName;
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('image_gen/media');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late StudioStore store;
  late _Picker picker;
  late FilePickerPlatform originalPicker;
  final bytes = Uint8List.fromList([137, 80, 78, 71]);
  final asset = ImageAsset(id: 'a' * 64, hash: 'a' * 64, path: 'assets/${'a' * 64}.png', mime: 'image/png', bytes: bytes.length);

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    root = await Directory.systemTemp.createTemp('image-gen-media-');
    store = StudioStore(_UnusedDatabase(), root);
    await Directory('${root.path}/assets').create();
    await store.fileFor(asset).writeAsBytes(bytes);
    originalPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    FilePickerPlatform.instance = originalPicker;
    debugDefaultTargetPlatformOverride = null;
    store.dispose();
    await root.delete(recursive: true);
  });

  test('Android 相册成功时传递本地路径和 MIME，不打开文件窗口', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveToGallery');
      expect(call.arguments, {'path': store.fileFor(asset).path, 'mime': 'image/png'});
      return true;
    });
    expect(await saveImageToDevice(store, asset), isTrue);
    expect(picker.calls, 0);
  });

  test('旧 Android 不支持相册时文件另存保持原始字节和 MIME', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await saveImageToDevice(store, asset), isTrue);
    expect(picker.calls, 1);
    expect(picker.savedBytes, bytes);
    expect(picker.savedMime, 'image/png');
    expect(picker.savedName, 'image_aaaaaaaa.png');
  });

  test('相册权限或存储错误时转到系统文件保存窗口', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'save_failed', message: '系统拒绝写入相册'));
    expect(await saveImageToDevice(store, asset), isTrue);
    expect(picker.calls, 1);
  });

  test('原生通道不可用时也可以文件另存', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw MissingPluginException());
    expect(await saveImageToDevice(store, asset), isTrue);
    expect(picker.calls, 1);
  });

  test('取消文件窗口不报告保存成功', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    picker.result = null;
    expect(await saveImageToDevice(store, asset), isFalse);
  });

  test('相册和文件另存均失败时保留相册原因及替代操作', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'save_failed', message: '存储空间不足'));
    picker.error = PlatformException(code: 'picker_failed');
    await expectLater(saveImageToDevice(store, asset), throwsA(isA<PlatformException>().having((e) => e.message, 'message', allOf(contains('存储空间不足'), contains('分享 / 导出')))));
  });

  test('SVG 直接文件另存，丢失的本地文件不会提示成功', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => fail('SVG 不应调用相册通道'));
    final svg = ImageAsset(id: 'b' * 64, hash: 'b' * 64, path: 'assets/${'b' * 64}.svg', mime: 'image/svg+xml', bytes: 6);
    await store.fileFor(svg).writeAsString('<svg/>');
    expect(await saveImageToDevice(store, svg), isTrue);
    expect(picker.savedMime, 'image/svg+xml');
    await store.fileFor(svg).delete();
    await expectLater(saveImageToDevice(store, svg), throwsA(isA<FileSystemException>()));
    expect(picker.calls, 1);
  });
}
