import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import '../models/models.dart';

Future<Directory?> prepareStudioRoot(Directory? directory) async {
  final root = directory ?? await getApplicationSupportDirectory();
  await root.create(recursive: true);
  return root;
}

DatabaseFactory studioDatabaseFactory() {
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }
  return databaseFactory;
}

File studioFile(Directory root, String path) => File('${root.path}/$path');

Future<void> writeStudioFile(
  Directory root,
  String path,
  Uint8List bytes,
) async {
  await Directory('${root.path}/assets').create(recursive: true);
  final temporary = studioFile(root, 'assets/.${newId()}.tmp');
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename('${root.path}/$path');
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
