import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 真 manager + 真 registry：验证安装前清单只读、初装禁用、禁用后工具不可调用。
Uint8List _package() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        'plugin.json',
        utf8.encode(
          jsonEncode({
            'id': 'com.example.upscale',
            'name': '示例增强',
            'version': '1.0.0',
            'apiVersion': 1,
            'entry': 'index.js',
            'permissions': {
              'credentials': ['api.example.com'],
              'image': true,
            },
            'processors': [
              {'id': 'example.sharpen', 'name': '示例锐化', 'process': 'sharpen'},
            ],
            'tools': [
              {
                'id': 'example.sharpen-tool',
                'name': '示例锐化工具',
                'processorId': 'example.sharpen',
              },
            ],
          }),
        ),
      ),
    )
    ..addFile(
      ArchiveFile.bytes(
        'index.js',
        utf8.encode('function sharpen(payload) { return {operations: []}; }'),
      ),
    );
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  late PluginManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-consent-');
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

  test('安装前清单只读，安装后默认禁用且工具不可调用', () async {
    final bytes = _package();
    final manifest = await manager.inspect(bytes);
    expect(manifest.name, '示例增强');
    expect(manifest.version, '1.0.0');
    expect(manifest.processors.single.id, 'example.sharpen');
    expect(manifest.tools.single.id, 'example.sharpen-tool');
    expect(manifest.permissions.credentials, {'api.example.com'});
    // 取消安装时磁盘上不能有任何痕迹。
    expect(await store.setting(pluginIndexKey), isNull);
    expect(Directory('${store.root.path}/plugins').existsSync(), isFalse);

    final installed = await manager.install(bytes);
    expect(installed.enabled, isFalse);

    final registry = await PluginRegistry.load(store);
    addTearDown(registry.dispose);
    expect(
      registry.tools.map((tool) => tool.id),
      isNot(contains('example.sharpen-tool')),
    );
    expect(
      () => registry.processor(
        const ProcessingStep(
          pluginId: 'com.example.upscale',
          version: '1.0.0',
          processorId: 'example.sharpen',
        ),
      ),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('请检查插件是否已安装或启用'),
        ),
      ),
    );
  });

  test('禁用内置本地处理后工具与处理器都不可调用，重新启用后恢复', () async {
    await manager.setEnabled(builtinLocalToolsPluginId, false);
    final disabled = await PluginRegistry.load(store);
    addTearDown(disabled.dispose);
    expect(disabled.tools.map((tool) => tool.id), isEmpty);
    expect(
      () => disabled.processor(
        const ProcessingStep(
          pluginId: builtinLocalToolsPluginId,
          version: '',
          processorId: 'local.watermark',
        ),
      ),
      throwsA(isA<PluginException>()),
    );

    await manager.setEnabled(builtinLocalToolsPluginId, true);
    final enabled = await PluginRegistry.load(store);
    addTearDown(enabled.dispose);
    expect(
      enabled.tools.map((tool) => tool.id),
      containsAll(<String>['tool.watermark', 'tool.resize']),
    );
    final processor = enabled.processor(
      const ProcessingStep(
        pluginId: builtinLocalToolsPluginId,
        version: '1.0.0',
        processorId: 'local.watermark',
      ),
    );
    expect(processor.descriptor.id, 'local.watermark');
    expect(enabled.issues, isEmpty);
  });
}

const String builtinLocalToolsPluginId = 'builtin.local-tools';
