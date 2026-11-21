import 'dart:io' show Directory, File;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

@JS('isSecureContext')
external bool get _isSecureContext;
Future<Directory?> prepareStudioRoot(Directory? directory) async {
  if (!_isSecureContext) throw UnsupportedError('Web 存储需要 HTTPS 或 localhost');
  if (directory != null) throw UnsupportedError('Web 不支持指定存储目录');
  return null;
}

DatabaseFactory studioDatabaseFactory() => databaseFactoryFfiWeb;

File studioFile(Directory root, String path) =>
    throw UnsupportedError('Web 图片请使用 readAsset 读取');

Future<void> writeStudioFile(Directory root, String path, Uint8List bytes) =>
    throw UnsupportedError('Web 图片保存在数据库中');
