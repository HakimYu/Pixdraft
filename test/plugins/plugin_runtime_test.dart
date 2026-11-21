import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_runtime.dart';
import 'package:image_gen/plugins/local_processing.dart';
import 'jsf_support.dart';

final _manifest = PluginManifest.fromJson({
  'id': 'com.example.upscale',
  'name': '示例插件',
  'version': '1.0.0',
  'apiVersion': 1,
  'entry': 'index.js',
  'permissions': {'credentials': ['api.example.com']},
  'processors': [
    {'id': 'example.resize', 'name': '示例缩放', 'process': 'resize'},
  ],
});

PluginScript compile(String body) => PluginScript.compile(manifest: _manifest, source: body);

// 1x1 PNG，本地处理按真实格式识别。
final _png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));

void main() {
  final ready = jsfAvailable();
  final skip = ready ? false : '缺少 libjsf 原生库：设置 JSF_LIBRARY_PATH 后重跑';

  test('脚本可编译并调用纯函数', () {
    final script = compile('function add(payload) { return payload.a + payload.b; }');
    addTearDown(script.dispose);
    expect(script.call('add', {'a': 2, 'b': 3}), 5);
  }, skip: skip);

  test('语法错误在编译期失败', () {
    expect(() => compile('function broken( {'), throwsA(isA<PluginScriptException>()));
  }, skip: skip);

  test('同步死循环被中断处理器硬切断，之后运行时仍可用', () {
    final script = compile('function spin() { while (true) {} } function echo(payload) { return payload.value; }');
    addTearDown(script.dispose);
    final stopwatch = Stopwatch()..start();
    expect(
      () => script.call('spin', const {}),
      throwsA(isA<PluginScriptException>().having((error) => error.timedOut, 'timedOut', isTrue).having((error) => error.message, 'message', contains('已强制中断'))),
    );
    stopwatch.stop();
    // 由 QuickJS 中断处理器在预算处返回，不是等待 Future 超时。
    expect(stopwatch.elapsed, lessThan(pluginScriptTimeout * 2));
    expect(script.call('echo', {'value': 'ok'}), 'ok');
  }, skip: skip);

  test('脚本拿不到网络、文件与 Dart 能力', () {
    final script = compile('''
function probe(payload) {
  return [typeof fetch, typeof XMLHttpRequest, typeof WebSocket, typeof require,
          typeof process, typeof Dart, typeof globalThis.dart, typeof globalThis.host].join(',');
}
''');
    addTearDown(script.dispose);
    expect(script.call('probe', const {}), List.filled(8, 'undefined').join(','));
  }, skip: skip);

  test('处理器脚本只产出操作，由本地模块执行', () async {
    final script = compile('''
function resize(payload) { return {operations: [{operation: 'resize', params: {width: 1, height: 1}}]}; }
''');
    addTearDown(script.dispose);
    final processor = PluginScriptProcessor(
      descriptor: const ProcessorDescriptor(id: 'example.resize', pluginId: 'com.example.upscale', version: '1.0.0', name: '示例缩放'),
      function: 'resize',
      script: script,
    );
    final image = ImageAsset(id: 'a1', path: 'assets/a1.png', mime: 'image/png', hash: 'h', bytes: _png.length, width: 1, height: 1);
    Uint8List? saved;
    final asset = await processor.process(image, const {}, ProcessingContext(readImage: (_) async => _png, saveImage: (bytes, mime) async {
      saved = bytes;
      return ImageAsset(id: 'a2', path: 'assets/a2.png', mime: mime, hash: 'h2', bytes: bytes.length);
    }));
    expect(saved, isNotNull);
    expect(asset.id, 'a2');
  }, skip: skip);

  test('处理器脚本拿到不存在的操作时报错', () {
    final script = compile('function bad(payload) { return {operations: [{operation: "explode", params: {}}]}; }');
    addTearDown(script.dispose);
    expect(() => PluginOperation.parse(script.call('bad', const {}), 'process'), returnsNormally);
    expect(() => applyLocalImageOperation(_png, 'explode', const {}), throwsA(isA<FormatException>()));
  }, skip: skip);
}