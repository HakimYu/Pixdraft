import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/plugins/plugin_toolkit.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/local_processing.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore(Directory root) : super(_UnusedDatabase(), root);
  Uint8List? saved;

  @override
  File fileFor(ImageAsset asset) => File('${root.path}/${asset.path}');

  @override
  Future<ImageAsset> saveAsset(Uint8List bytes, String mime, {String? remoteUrl}) async {
    saved = bytes;
    return ImageAsset(id: 'out', path: _path, mime: mime, hash: '0' * 64, bytes: bytes.length);
  }
}

final _path = 'assets/0000000000000000000000000000000000000000000000000000000000000000.png';

ImageAsset _source(File file) => ImageAsset(id: 'src', path: 'assets/${'0' * 64}.png', mime: 'image/png', hash: '0' * 64, bytes: file.lengthSync());

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('toolkit_test'));
  tearDown(() async => root.delete(recursive: true));

  test('内置工具与处理器一一对应', () async {
    final toolkit = PluginToolkit.builtin(_FakeStore(root));
    final processorIds = {for (final processor in createBuiltinProcessors()) processor.descriptor.id};
    expect(toolkit.tools, isNotEmpty);
    expect(toolkit.tools.map((tool) => tool.processorId).toSet(), processorIds);
    expect(toolkit.tools.map((tool) => tool.id), containsAll(['tool.watermark', 'tool.resize']));
  });

  test('内置工具集按步骤处理并返回新图，不改源图', () async {
    final file = File('${root.path}/$_path')..createSync(recursive: true);
    file.writeAsBytesSync(img.encodePng(img.fill(img.Image(width: 60, height: 40), color: img.ColorRgb8(20, 40, 60))));
    final before = file.readAsBytesSync();
    final store = _FakeStore(root);
    final step = ProcessingStep(pluginId: builtinLocalPluginId, version: builtinLocalVersion, processorId: 'local.watermark', params: {'text': '内部', 'opacity': 1.0, 'scale': 0.5});
    final asset = await PluginToolkit.builtin(store).process(_source(file), step);
    expect(asset.mime, 'image/png');
    expect(store.saved, isNotNull);
    expect(store.saved, isNot(before));
    expect(file.readAsBytesSync(), before, reason: '源图不被覆盖');
  });

  test('未知处理器与取消都在保存前失败', () async {
    final file = File('${root.path}/$_path')..createSync(recursive: true);
    file.writeAsBytesSync(img.encodePng(img.Image(width: 20, height: 20)));
    final store = _FakeStore(root);
    final toolkit = PluginToolkit.builtin(store);
    expect(() => toolkit.process(_source(file), const ProcessingStep(pluginId: builtinLocalPluginId, version: builtinLocalVersion, processorId: 'local.unknown')), throwsFormatException);
    await expectLater(
      toolkit.process(_source(file), const ProcessingStep(pluginId: builtinLocalPluginId, version: builtinLocalVersion, processorId: 'local.resize', params: {'width': 10}), isCancelled: () => true),
      throwsA(isA<ProcessingCancelled>()),
    );
    expect(store.saved, isNull);
  });
}