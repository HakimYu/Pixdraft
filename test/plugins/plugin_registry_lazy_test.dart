import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'jsf_support.dart';

Uint8List packageBytes(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = entry.value;
    archive.addFile(
      ArchiveFile.bytes(
        entry.key,
        data is String ? utf8.encode(data) : data as List<int>,
      ),
    );
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

Map<String, dynamic> manifestJson(String version) => {
  'id': 'com.example.lazy',
  'name': '惰性加载示例',
  'version': version,
  'apiVersion': 1,
  'entry': 'index.js',
  'permissions': {
    'credentials': <String>[],
    'image': true,
  },
  'providers': <Map<String, dynamic>>[],
  'processors': [
    {'id': 'lazy.resize', 'name': '惰性缩放', 'process': 'resize'},
  ],
  'tools': <Map<String, dynamic>>[],
};

const String goodScript = '''
function resize(payload) {
  return {operations: [{operation: 'resize', params: {width: 1, height: 1}}]};
}
''';

/// 入口一 eval 就抛错：只有真的加载它才会留下 issue。
const String brokenScript = '''
throw new Error('2.0.0 不应被加载');
function resize(payload) {
  return {operations: [{operation: 'resize', params: {width: 1, height: 1}}]};
}
''';

Uint8List samplePackage(String version, String script) => packageBytes({
  'plugin.json': jsonEncode(manifestJson(version)),
  'index.js': script,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final skip = jsfAvailable() ? null : jsfSkipReason;
  late Directory directory;
  late StudioStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-lazy-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('按需加载只编译被 pin 的那个版本，不碰同插件的其它版本', () async {
    final manager = PluginManager(store);
    await manager.install(samplePackage('1.0.0', goodScript));
    await manager.install(samplePackage('2.0.0', brokenScript));
    await manager.setEnabled('com.example.lazy', false);

    final registry = await PluginRegistry.load(store);
    addTearDown(registry.dispose);

    final picture = img.Image(width: 2, height: 2);
    img.fill(picture, color: img.ColorRgb8(255, 0, 0));
    final source = await store.saveAsset(img.encodePng(picture), 'image/png');

    final result = await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'com.example.lazy',
        version: '1.0.0',
        processorId: 'lazy.resize',
      ),
    );

    expect(result.id, isNot(source.id));
    // 2.0.0 的入口一执行就抛错；它没被编译，因此不会出现在 issues 里。
    expect(registry.issues.where((item) => item.contains('2.0.0')), isEmpty);
  }, skip: skip);
}