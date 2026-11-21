import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String _script = '''
function plan(payload) { return {url: 'https://api.example.com/v1', method: 'POST', body: payload}; }
function interpret(response) { return {images: []}; }
function process(payload) { return {operations: []}; }
''';

Map<String, dynamic> _manifestJson({
  required String id,
  String version = '1.0.0',
  List<String> providerIds = const [],
  List<String> processorIds = const [],
  List<String> toolIds = const [],
}) => {
  'id': id,
  'name': id,
  'version': version,
  'apiVersion': 1,
  'entry': 'index.js',
  'permissions': {'credentials': <String>[], 'image': true},
  'providers': [
    for (final extensionId in providerIds)
      {
        'id': extensionId,
        'name': extensionId,
        'plan': 'plan',
        'interpret': 'interpret',
      },
  ],
  'processors': [
    for (final extensionId in processorIds)
      {'id': extensionId, 'name': extensionId, 'process': 'process'},
  ],
  'tools': [
    for (final extensionId in toolIds)
      {'id': extensionId, 'name': extensionId, 'processorId': 'x.processor'},
  ],
};

Uint8List _package({
  required String id,
  String version = '1.0.0',
  String? adapterId,
  String? processorId,
}) {
  final adapter = adapterId ?? '$id.adapter';
  final processor = processorId ?? '$id.processor';
  final manifest = {
    ..._manifestJson(id: id, version: version),
    'providers': [
      {
        'id': adapter,
        'name': adapter,
        'plan': 'plan',
        'interpret': 'interpret',
      },
    ],
    'processors': [
      {'id': processor, 'name': processor, 'process': 'process'},
    ],
    'tools': [
      {'id': '$id.tool', 'name': id, 'processorId': processor},
    ],
  };
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('plugin.json', utf8.encode(jsonEncode(manifest))),
    )
    ..addFile(ArchiveFile.bytes('index.js', utf8.encode(_script)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// 把同名条目塞进包里：Archive.add 会去重，所以直接改 ZIP 里的文件名
/// （本地头与中央目录各一份），模拟「后者覆盖前者」的原始重复路径。
Uint8List _withDuplicateEntry(Uint8List zip) {
  final bytes = Uint8List.fromList(zip);
  final needle = ascii.encode('xndex.js');
  final replacement = ascii.encode('index.js');
  var patched = 0;
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (!hit) continue;
    bytes.setRange(i, i + needle.length, replacement);
    patched++;
  }
  expect(patched, 2, reason: '期望同时改到本地头与中央目录');
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  late PluginManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-identity-');
    store = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: directory,
    );
    manager = PluginManager(store);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Matcher rejects(String text) => throwsA(
    isA<PluginException>().having(
      (error) => error.message,
      'message',
      contains(text),
    ),
  );

  test('清单拒绝内置扩展保留名', () {
    for (final json in [
      _manifestJson(id: 'com.evil.images', providerIds: ['images']),
      _manifestJson(id: 'com.evil.resize', processorIds: ['local.resize']),
      _manifestJson(id: 'com.evil.watermark', toolIds: ['tool.watermark']),
    ]) {
      expect(() => PluginManifest.fromJson(json), rejects('属于内置插件'));
    }
  });

  test('恶意高版本 images 无法经安装接管内置适配器', () async {
    expect(
      () => manager.inspect(
        _package(id: 'com.evil.other', version: '9.0.0', adapterId: 'images'),
      ),
      rejects('属于内置插件'),
    );
    await expectLater(
      manager.install(
        _package(id: 'com.evil.other', version: '9.0.0', adapterId: 'images'),
      ),
      rejects('属于内置插件'),
    );
    expect(Directory('${store.root.path}/plugins').existsSync(), isFalse);
    expect(await store.setting(pluginIndexKey), isNull);
  });

  test('不同插件争同一 adapterId 被拒，卸载留档后仍不能抢', () async {
    await manager.install(_package(id: 'com.example.base'));
    final thief = _package(
      id: 'com.evil.takeover',
      version: '9.0.0',
      adapterId: 'com.example.base.adapter',
    );

    await expectLater(
      manager.install(thief),
      rejects('已属于插件 com.example.base'),
    );

    await manager.uninstall('com.example.base');
    expect(
      (await manager.list()).where((plugin) => plugin.id == 'com.example.base'),
      isEmpty,
    );
    await expectLater(
      manager.install(thief),
      rejects('已属于插件 com.example.base'),
    );

    // 原插件自己的新版本照常安装，两版并存，旧版仍可供 pin 使用。
    await manager.install(_package(id: 'com.example.base', version: '2.0.0'));
    final plugin = (await manager.list()).firstWhere(
      (item) => item.id == 'com.example.base',
    );
    expect(plugin.versions, ['2.0.0', '1.0.0']);
    final pinned = await manager.installationAt('com.example.base', '1.0.0');
    expect(pinned?.plugin.manifest?.version, '1.0.0');
  });

  test('重复条目名与符号链接在解码前被拒，且不落盘', () async {
    final manifest = utf8.encode(
      jsonEncode(
        _manifestJson(id: 'com.evil.zip', providerIds: ['com.evil.a']),
      ),
    );
    final duplicated = Archive()
      ..addFile(ArchiveFile.bytes('plugin.json', manifest))
      ..addFile(ArchiveFile.bytes('index.js', utf8.encode(_script)))
      ..addFile(ArchiveFile.bytes('xndex.js', utf8.encode('function a() {}')));
    final duplicateBytes = _withDuplicateEntry(
      Uint8List.fromList(ZipEncoder().encodeBytes(duplicated)),
    );
    await expectLater(
      manager.inspect(duplicateBytes),
      rejects('插件包内路径重复：index.js'),
    );
    await expectLater(
      manager.install(duplicateBytes),
      rejects('插件包内路径重复：index.js'),
    );

    final linked = Archive()
      ..addFile(ArchiveFile.bytes('plugin.json', manifest))
      ..addFile(ArchiveFile.symlink('index.js', 'a' * (5 * 1024 * 1024)));
    await expectLater(
      manager.inspect(Uint8List.fromList(ZipEncoder().encodeBytes(linked))),
      rejects('插件包不允许符号链接：index.js'),
    );

    expect(await store.setting(pluginIndexKey), isNull);
    expect(Directory('${store.root.path}/plugins').existsSync(), isFalse);
  });
}
