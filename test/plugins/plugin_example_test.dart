import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image/image.dart' as img;
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:image_gen/plugins/plugin_runtime.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'jsf_support.dart';

/// 示例插件同时是安装流程与脚本运行的最小验收样例。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final directory = Directory('examples/plugins/example-stamp');
  final manifestJson = jsonDecode(
    File('${directory.path}/plugin.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final source = File('${directory.path}/index.js').readAsStringSync();

  Uint8List package() {
    final archive = Archive();
    for (final name in ['plugin.json', 'index.js']) {
      archive.addFile(
        ArchiveFile.bytes(
          name,
          File('${directory.path}/$name').readAsBytesSync(),
        ),
      );
    }
    return ZipEncoder().encodeBytes(archive);
  }

  test('示例清单通过校验，声明处理器与工具', () {
    final manifest = PluginManifest.fromJson(manifestJson);
    expect(manifest.id, 'com.example.stamp');
    expect(manifest.version, '1.0.0');
    expect(manifest.processors.single.id, 'example.stamp');
    expect(manifest.tools.single.processorId, 'example.stamp');
    expect(manifest.permissions.credentials, isEmpty);
  });

  test('示例插件包可导入，初装未启用', () async {
    final root = await Directory.systemTemp.createTemp('example-');
    addTearDown(() => root.delete(recursive: true));
    final store = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: root,
    );
    addTearDown(store.close);

    final manager = PluginManager(store);
    final inspected = await manager.inspect(package());
    expect(inspected.id, 'com.example.stamp');

    await manager.install(package());
    final installed = (await manager.list()).firstWhere(
      (plugin) => plugin.id == 'com.example.stamp',
    );
    expect(installed.enabled, isFalse);
    expect(installed.builtIn, isFalse);
    expect(installed.versions, ['1.0.0']);

    await manager.setEnabled('com.example.stamp', true);
    expect(
      (await manager.list())
          .firstWhere((plugin) => plugin.id == 'com.example.stamp')
          .enabled,
      isTrue,
    );
  });

  test('示例脚本返回本地操作，图片处理离线完成', () {
    final manifest = PluginManifest.fromJson(manifestJson);
    final script = PluginScript.compile(manifest: manifest, source: source);
    addTearDown(script.dispose);

    final output = pluginScriptObject(
      script.call('stamp', {
        'params': {'text': '验收'},
      }),
      'stamp',
    );
    final operations = PluginOperation.parse(output, 'stamp');
    expect(operations, hasLength(2));
    expect(operations.first.operation, 'watermark');
    expect(operations.first.params['text'], contains('验收'));
    expect(operations.last.params['position'], '左上');
  }, skip: jsfAvailable() ? false : jsfSkipReason);

  test('示例插件端到端：安装→启用→可见→真实图片处理', () async {
    final root = await Directory.systemTemp.createTemp('example-e2e-');
    addTearDown(() => root.delete(recursive: true));
    final store = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: root,
    );
    addTearDown(store.close);

    final manager = PluginManager(store);
    await manager.install(package());

    var registry = await PluginRegistry.load(store);
    expect(registry.tools.where((tool) => tool.id == 'tool.stamp'), isEmpty);
    expect(
      registry.processors.where((item) => item.id == 'example.stamp'),
      isEmpty,
    );
    await registry.dispose();

    await manager.setEnabled('com.example.stamp', true);
    registry = await PluginRegistry.load(store);
    addTearDown(registry.dispose);

    expect(
      registry.tools.singleWhere((tool) => tool.id == 'tool.stamp').pluginId,
      'com.example.stamp',
    );
    expect(
      registry.processors
          .singleWhere((item) => item.id == 'example.stamp')
          .pluginId,
      'com.example.stamp',
    );

    final image = img.Image(width: 8, height: 6);
    img.fill(image, color: img.ColorRgb8(20, 40, 200));
    final sourceAsset = await store.saveAsset(
      Uint8List.fromList(img.encodePng(image)),
      'image/png',
    );
    final sourceBytes = await store.fileFor(sourceAsset).readAsBytes();

    final result = await registry.process(
      sourceAsset,
      const ProcessingStep(
        pluginId: 'com.example.stamp',
        version: '1.0.0',
        processorId: 'example.stamp',
        params: {'text': '验收', 'opacity': 0.9},
      ),
    );

    expect(result.id, isNot(sourceAsset.id));
    final resultBytes = await store.fileFor(result).readAsBytes();
    expect(resultBytes, isNot(equals(sourceBytes)));
    final decoded = img.decodePng(resultBytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, image.width);
    expect(decoded.height, image.height);
    expect(await store.fileFor(sourceAsset).readAsBytes(), sourceBytes);
  }, skip: jsfAvailable() ? false : jsfSkipReason);
}
