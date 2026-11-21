@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('IndexedDB 重开保留图片，恢复事务回滚，清理连带删除字节', () async {
    final factory = createDatabaseFactoryFfiWeb(
      options: SqfliteFfiWebOptions(
        indexedDbName: 'studio-test-${DateTime.now().microsecondsSinceEpoch}',
        sharedWorkerUri: Uri.parse('/sqflite_sw.js'),
        sqlite3WasmUri: Uri.parse('/sqlite3.wasm'),
      ),
    );
    var store = await StudioStore.open(factory: factory);
    addTearDown(() async {
      if (store.db.isOpen) await store.close();
      await factory.deleteDatabase('studio.db');
    });
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );
    final asset = await store.saveAsset(png, 'image/png');
    expect((await store.saveAsset(png, 'image/png')).id, asset.id);
    await store.close();
    store = await StudioStore.open(factory: factory);
    expect(await store.assetLength(asset), png.length);
    expect(await store.readAsset(asset), png);
    expect(await store.db.query('asset_bytes'), hasLength(1));

    const fake = ImageAsset(
      id: 'bad',
      path: '../secret',
      mime: 'image/png',
      hash: 'bad',
      bytes: 1,
    );
    await expectLater(store.readAsset(fake), throwsFormatException);

    await store.db.update('asset_bytes', {'created_at': 0});
    await store.saveSetting('draft', {'image': asset.toJson()});
    await store.pruneOrphanAssets();
    expect(await store.readAsset(asset), png);
    await store.db.delete('settings');
    await store.pruneOrphanAssets();
    expect(await store.db.query('assets'), isEmpty);
    expect(await store.db.query('asset_bytes'), isEmpty);
    await expectLater(store.readAsset(asset), throwsStateError);

    Future<void> restore({required bool abort}) =>
        store.db.transaction((tx) async {
          await tx.insert('assets', {
            'id': asset.id,
            'hash': asset.hash,
            'data': jsonEncode(asset.toJson()),
          });
          await store.writeRestoredAssetBytes(tx, asset, png);
          if (abort) throw StateError('测试回滚');
        });
    await expectLater(restore(abort: true), throwsStateError);
    expect(await store.db.query('assets'), isEmpty);
    expect(await store.db.query('asset_bytes'), isEmpty);
    await restore(abort: false);
    expect(await store.readAsset(asset), png);
  });
}
