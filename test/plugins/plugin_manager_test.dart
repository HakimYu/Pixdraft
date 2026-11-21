import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List packageBytes(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = entry.value;
    archive.addFile(data is ArchiveFile ? data : ArchiveFile.bytes(entry.key, data is String ? utf8.encode(data) : data as List<int>));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

Map<String, dynamic> manifestJson({String id = 'com.example.upscale', String version = '1.0.0', String entry = 'index.js', int apiVersion = 1, Map<String, dynamic>? providers, Map<String, dynamic>? permissions}) => {
      'id': id,
      'name': '示例插件',
      'version': version,
      'apiVersion': apiVersion,
      'entry': entry,
      'permissions': permissions ?? {'credentials': ['api.example.com'], 'image': true},
      'providers': [
        providers ??
            {
              'id': 'example.upscale',
              'name': '示例放大',
              'plan': 'plan',
              'interpret': 'interpret',
            }
      ],
      'processors': [
        {'id': 'example.sharpen', 'name': '示例锐化', 'process': 'sharpen'}
      ],
      'tools': [
        {'id': 'example.sharpen-tool', 'name': '示例锐化工具', 'processorId': 'example.sharpen'}
      ],
    };

const String sampleScript = '''
function plan(payload) { return {url: 'https://api.example.com/v1/images', method: 'POST', body: payload}; }
function interpret(response) { return {images: []}; }
function sharpen(payload) { return {operations: []}; }
''';

Uint8List samplePackage({String version = '1.0.0', String script = sampleScript, Map<String, dynamic>? manifest}) => packageBytes({
      'plugin.json': jsonEncode(manifest ?? manifestJson(version: version)),
      'index.js': script,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  late PluginManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-manager-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    manager = PluginManager(store);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('inspect 只读校验清单，不落盘也不执行脚本', () async {
    final manifest = await manager.inspect(samplePackage());
    expect(manifest.id, 'com.example.upscale');
    expect(manifest.processors.single.id, 'example.sharpen');
    expect(await store.setting(pluginIndexKey), isNull);
    expect(Directory('${store.root.path}/plugins').existsSync(), isFalse);
  });

  test('初装默认不启用，启用后 list 反映状态', () async {
    final installed = await manager.install(samplePackage());
    expect(installed.enabled, isFalse);
    expect(installed.version, '1.0.0');
    expect(installed.versions, ['1.0.0']);

    var listed = await manager.list();
    final plugin = listed.firstWhere((item) => item.id == 'com.example.upscale');
    expect(plugin.enabled, isFalse);
    expect(listed.where((item) => item.builtIn).map((item) => item.id), ['builtin.providers', 'builtin.local-tools']);

    await manager.setEnabled('com.example.upscale', true);
    listed = await manager.list();
    expect(listed.firstWhere((item) => item.id == 'com.example.upscale').enabled, isTrue);
  });

  test('同版本不同内容拒绝覆盖，旧版本保持可用', () async {
    await manager.install(samplePackage());
    final before = File('${store.root.path}/plugins/com.example.upscale/1.0.0/index.js').readAsStringSync();

    await expectLater(
      manager.install(samplePackage(script: '$sampleScript\n// 变更')),
      throwsA(isA<PluginException>().having((error) => error.message, 'message', contains('请提升版本号'))),
    );
    expect(File('${store.root.path}/plugins/com.example.upscale/1.0.0/index.js').readAsStringSync(), before);

    final second = await manager.install(samplePackage(version: '1.0.1'));
    expect(second.version, '1.0.1');
    expect(second.versions, ['1.0.1', '1.0.0']);
  });

  test('ZIP 路径逃逸、符号链接与超量文件都被拒绝', () async {
    await expectLater(
      manager.install(packageBytes({'plugin.json': jsonEncode(manifestJson()), 'index.js': sampleScript, '../evil.js': 'x'})),
      throwsA(isA<PluginException>().having((error) => error.message, 'message', contains('路径逃逸'))),
    );
    await expectLater(
      manager.install(packageBytes({
        'plugin.json': jsonEncode(manifestJson()),
        'index.js': sampleScript,
        'link.js': ArchiveFile.symlink('link.js', '/etc/passwd'),
      })),
      throwsA(isA<PluginException>().having((error) => error.message, 'message', contains('符号链接'))),
    );
    final many = <String, Object>{'plugin.json': jsonEncode(manifestJson()), 'index.js': sampleScript};
    for (var i = 0; i <= pluginMaxFiles; i++) {
      many['data/$i.txt'] = 'x';
    }
    await expectLater(
      manager.install(packageBytes(many)),
      throwsA(isA<PluginException>().having((error) => error.message, 'message', contains('文件数'))),
    );
  });

  test('清单不合法时拒绝安装且不留目录', () async {
    final cases = <String, Map<String, dynamic>>{
      '内置保留 ID': manifestJson(id: 'builtin.providers'),
      '版本格式': manifestJson(version: '1.0'),
      'API 版本': manifestJson(apiVersion: 2),
      '入口缺失': manifestJson(entry: 'missing.js'),
      '未知处理器': {...manifestJson(), 'tools': [{'id': 'example.tool', 'name': '工具', 'processorId': 'nope'}]},
      '未授权域名': manifestJson(permissions: {'credentials': ['*.example.com']}),
    };
    for (final entry in cases.entries) {
      await expectLater(manager.install(samplePackage(manifest: entry.value)), throwsA(isA<PluginException>()), reason: entry.key);
    }
    expect(Directory('${store.root.path}/plugins/com.example.upscale').existsSync(), isFalse);
  });

  test('入口脚本必须是包内 UTF-8 文本', () async {
    await expectLater(
      manager.install(packageBytes({'plugin.json': jsonEncode(manifestJson()), 'index.js': [0xff, 0xfe, 0xfd]})),
      throwsA(isA<PluginException>().having((error) => error.message, 'message', contains('UTF-8'))),
    );
  });

  test('卸载拒绝新入口但保留磁盘版本，版本仍可按 pin 读取', () async {
    await manager.install(samplePackage());
    await manager.setEnabled('com.example.upscale', true);
    await manager.uninstall('com.example.upscale');

    expect((await manager.list()).where((item) => item.id == 'com.example.upscale'), isEmpty);
    expect(Directory('${store.root.path}/plugins/com.example.upscale/1.0.0').existsSync(), isTrue);

    final installations = await manager.allInstallations();
    expect(installations.map((item) => '${item.plugin.id}@${item.version}'), ['com.example.upscale@1.0.0']);
    final pinned = await manager.installationAt('com.example.upscale', '1.0.0');
    expect(pinned?.plugin.manifest?.entry, 'index.js');
    expect(await manager.installationAt('com.example.upscale', '9.9.9'), isNull);
    expect((await manager.activeInstallations()), isEmpty);
  });

  test('内置插件不可卸载，启停写回索引', () async {
    await expectLater(manager.uninstall('builtin.local-tools'), throwsA(isA<PluginException>()));
    await manager.setEnabled('builtin.local-tools', false);
    expect((await manager.list()).firstWhere((item) => item.id == 'builtin.local-tools').enabled, isFalse);
    await manager.setEnabled('builtin.local-tools', true);
    expect((await manager.list()).firstWhere((item) => item.id == 'builtin.local-tools').enabled, isTrue);
    await expectLater(manager.setEnabled('com.example.absent', true), throwsA(isA<PluginException>()));
  });
}