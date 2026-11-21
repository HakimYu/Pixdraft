import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeProvider implements ProviderExtension {
  FakeProvider(this.descriptor);

  @override
  final ProviderDescriptor descriptor;
  final List<String> cancelled = [];
  final List<String> generated = [];

  /// 非空时 generate 停在这里，模拟一个真正进行中的请求。
  Completer<void>? gate;

  @override
  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  }) => const GenerationCapabilities(maxReferences: 4);

  @override
  Future<List<String>> discoverModels(
    ProviderConfig provider,
    String? apiKey,
  ) async => ['fake-model'];

  @override
  Future<GenerationPlan> plan(GenerationInput input) async =>
      GenerationPlan(input: input, expectedCount: 1);

  @override
  Stream<GenerationEvent> generate(
    GenerationInput input,
    String apiKey,
  ) async* {
    generated.add('${input.taskId}:${descriptor.version}');
    final wait = gate;
    if (wait != null) await wait.future;
    yield const GenerationEvent('done');
  }

  @override
  void cancel(String taskId) => cancelled.add('$taskId:${descriptor.version}');
}

class FakeProcessor implements ImageProcessorExtension {
  FakeProcessor(this.descriptor, {this.output});

  @override
  final ProcessorDescriptor descriptor;

  /// 为空时原样回写输入，非空时写另一张图（内容不同才不会被 store 去重）。
  final Uint8List? output;
  int calls = 0;

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    calls++;
    final bytes = await context.readImage(image);
    return context.saveImage(output ?? bytes, 'image/png');
  }
}

/// 故意去读本次输入以外的资产，用来验证 registry.process 的真实 context 守卫。
class SneakyProcessor implements ImageProcessorExtension {
  SneakyProcessor(this.descriptor, this.target);

  @override
  final ProcessorDescriptor descriptor;
  final ImageAsset target;
  Object? error;

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    try {
      await context.readImage(target);
    } on Object catch (failure) {
      error = failure;
    }
    final bytes = await context.readImage(image);
    return context.saveImage(bytes, 'image/png');
  }
}

/// 用自定义脚本验证 readImage/saveImage 的允许集合行为。
class ScriptedProcessor implements ImageProcessorExtension {
  ScriptedProcessor(this.descriptor, this.body);

  @override
  final ProcessorDescriptor descriptor;
  final Future<ImageAsset> Function(ImageAsset, ProcessingContext) body;
  Object? error;

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    try {
      return await body(image, context);
    } on Object catch (failure) {
      error = failure;
      rethrow;
    }
  }
}

/// 同一 id、指向另一张合法资产文件路径的伪造资产。
ImageAsset forgedPath(ImageAsset asset, String path) => ImageAsset(
  id: asset.id,
  path: path,
  mime: asset.mime,
  hash: asset.hash,
  bytes: asset.bytes,
);

/// 真正能解码的 PNG：内容不同，store 才不会按 hash 去重成同一份资产。
Uint8List solidPng(int red, int green, int blue) {
  final picture = img.Image(width: 2, height: 2);
  for (var y = 0; y < picture.height; y++) {
    for (var x = 0; x < picture.width; x++) {
      picture.setPixelRgb(x, y, red, green, blue);
    }
  }
  return img.encodePng(picture);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final redPng = solidPng(255, 0, 0);
  final bluePng = solidPng(0, 0, 255);
  late Directory directory;
  late StudioStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('registry-');
    store = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: directory,
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  ProviderConfig config(String adapterId, {String? version}) => ProviderConfig(
    id: 'p',
    name: '测试',
    baseUrl: 'https://api.example.com/v1',
    adapterId: adapterId,
    adapterVersion: version,
  );

  GenerationInput input(
    ProviderConfig provider, {
    String taskId = 't',
    List<ProcessingStep> pre = const [],
    List<ProcessingStep> post = const [],
  }) => GenerationInput(
    taskId: taskId,
    provider: provider,
    prompt: '猫',
    params: const GenerationParams(),
    preprocessors: pre,
    postprocessors: post,
  );

  ProviderDescriptor providerDescriptor(String id, String version) =>
      ProviderDescriptor(
        id: id,
        pluginId: 'builtin.providers',
        version: version,
        name: id,
      );

  test('未安装的 adapterId 明确拒绝，不回落到内置生图', () async {
    final registry = PluginRegistry.forTesting(store: store);
    await expectLater(
      registry.generate(input(config('com.example.missing')), 'key'),
      emitsError(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('未安装插件适配器'),
        ),
      ),
    );
  });

  test('pin 的版本未安装时报缺失，不换用其它版本', () async {
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [FakeProvider(providerDescriptor('images', '1.0.0'))],
    );
    await expectLater(
      registry.generate(input(config('images', version: '2.0.0')), 'key'),
      emitsError(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('不会自动换版'),
        ),
      ),
    );
    expect(registry.providers.single.version, '1.0.0');
  });

  test('未 pin 时使用已启用插件里的最高版本', () async {
    final oldProvider = FakeProvider(providerDescriptor('images', '1.0.0'));
    final newProvider = FakeProvider(providerDescriptor('images', '2.1.0'));
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [newProvider, oldProvider],
    );

    await registry
        .generate(input(config('images'), taskId: 'a'), 'key')
        .drain<void>();

    expect(newProvider.generated, ['a:2.1.0']);
    expect(oldProvider.generated, isEmpty);
  });

  test('不同插件不能接管同一 adapterId，恶意高版本也不会生效', () async {
    const builtin = ProviderDescriptor(
      id: 'images',
      pluginId: 'builtin.providers',
      version: '1.0.0',
      name: '内置',
    );
    const evil = ProviderDescriptor(
      id: 'images',
      pluginId: 'com.evil.other',
      version: '9.0.0',
      name: '冒充',
    );
    final builtinProvider = FakeProvider(builtin);
    final evilProvider = FakeProvider(evil);
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [builtinProvider, evilProvider],
    );

    expect(registry.providers.single.pluginId, 'builtin.providers');
    expect(registry.providers.single.version, '1.0.0');
    expect(registry.issues.single, contains('已属于插件 builtin.providers'));

    await registry
        .generate(input(config('images'), taskId: 'evil'), 'key')
        .drain<void>();
    expect(builtinProvider.generated, ['evil:1.0.0']);
    expect(evilProvider.generated, isEmpty);
  });

  test('两个动态插件争同一 adapterId：后注册的被拒并记录', () {
    final first = FakeProvider(
      const ProviderDescriptor(
        id: 'dup.adapter',
        pluginId: 'com.a',
        version: '1.0.0',
        name: 'a',
      ),
    );
    final second = FakeProvider(
      const ProviderDescriptor(
        id: 'dup.adapter',
        pluginId: 'com.b',
        version: '9.0.0',
        name: 'b',
      ),
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [first, second],
    );

    expect(registry.providers.single.pluginId, 'com.a');
    expect(registry.issues.single, contains('已属于插件 com.a'));
  });

  test('取消命中正在生成的那个 client，已结束的 client 不会被保留', () async {
    final provider = FakeProvider(providerDescriptor('wavespeed', '1.0.0'));
    final gate = Completer<void>();
    provider.gate = gate;
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [provider],
    );

    final events = <GenerationEvent>[];
    final subscription = registry
        .generate(input(config('wavespeed'), taskId: 'task-1'), 'key')
        .listen(events.add);
    while (provider.generated.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }

    registry.cancel('task-1');
    registry.cancel('task-1');
    gate.complete();
    await subscription.asFuture<void>();

    expect(provider.generated, ['task-1:1.0.0']);
    expect(provider.cancelled, ['task-1:1.0.0']);
    expect(events.single.kind, 'done');

    // 流已结束，client 已被释放：重复取消不会再打到它身上。
    registry.cancel('task-1');
    expect(provider.cancelled, ['task-1:1.0.0']);
  });

  test('client 启动前的取消会保留，同一 task 的新尝试重置取消状态', () async {
    final provider = FakeProvider(providerDescriptor('wavespeed', '1.0.0'));
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [provider],
    );

    // 排队后被取消：取消先于 client 启动，不能把请求发出去。
    final pending = registry.generate(
      input(config('wavespeed'), taskId: 'task-2'),
      'key',
    );
    registry.cancel('task-2');
    expect(await pending.toList(), isEmpty);
    expect(provider.generated, isEmpty);
    expect(provider.cancelled, isEmpty);

    // 同一个 task 的新尝试重新开始，不受上一次取消影响。
    await registry
        .generate(input(config('wavespeed'), taskId: 'task-2'), 'key')
        .drain<void>();
    expect(provider.generated, ['task-2:1.0.0']);
  });

  test('pinInput 把供应商与处理步骤的版本写进快照', () async {
    final provider = FakeProvider(providerDescriptor('images', '1.0.0'));
    final processor = FakeProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [provider],
      processors: [processor],
    );

    final pinned = await registry.pinInput(
      input(
        config('images'),
        post: [
          ProcessingStep(
            pluginId: 'builtin.local-tools',
            version: '',
            processorId: 'local.resize',
          ),
        ],
      ),
    );

    expect(pinned.provider.adapterVersion, '1.0.0');
    expect(pinned.postprocessors.single.version, '1.0.0');
    expect(pinned.preprocessors, isEmpty);
  });

  test('插件禁用后 pin 住的旧版仍可执行，但新提交被 pinInput 拒绝', () async {
    final manager = PluginManager(store);
    await manager.setEnabled('builtin.providers', false);
    await manager.setEnabled('builtin.local-tools', false);
    final registry = await PluginRegistry.load(store);
    addTearDown(registry.dispose);

    // 新提交：pin 了版本的供应商与处理链都在门口被拒绝。
    await expectLater(
      registry.pinInput(input(config('images', version: '1.0.0'))),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('已禁用'),
        ),
      ),
    );
    await expectLater(
      registry.pinInput(
        input(
          config('images', version: '1.0.0'),
          post: [
            ProcessingStep(
              pluginId: 'builtin.local-tools',
              version: '1.0.0',
              processorId: 'local.resize',
            ),
          ],
        ),
      ),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('已禁用'),
        ),
      ),
    );

    // 已领取/排队的工作仍按 pin 的精确旧版执行，不换版也不被禁用拦住。
    final source = await store.saveAsset(redPng, 'image/png');
    final result = await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        processorId: 'local.resize',
        params: {'width': 1, 'height': 1},
      ),
    );
    expect(result.id, isNot(source.id));
  });

  test('处理器只读本次输入的图片，结果写入 store.saveAsset', () async {
    final processor = FakeProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
      output: bluePng,
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      processors: [processor],
    );
    final source = await store.saveAsset(redPng, 'image/png');

    final result = await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        processorId: 'local.resize',
      ),
    );

    expect(result.id, isNot(source.id));
    expect(await store.fileFor(result).readAsBytes(), bluePng);
    expect(await store.fileFor(source).readAsBytes(), redPng);
  });

  test('处理器读本次输入以外的资产被真实 context 拒绝', () async {
    final source = await store.saveAsset(redPng, 'image/png');
    final other = await store.saveAsset(bluePng, 'image/png');
    expect(other.id, isNot(source.id));

    final processor = SneakyProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
      other,
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      processors: [processor],
    );

    await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        processorId: 'local.resize',
      ),
    );

    expect(processor.error, isA<PluginException>());
    expect(processor.error.toString(), contains('只能读取本次创建的图片'));
  });

  test('同 id 伪造 path 只能读到本次输入，读不到别的合法资产', () async {
    final source = await store.saveAsset(redPng, 'image/png');
    final other = await store.saveAsset(bluePng, 'image/png');
    expect(other.id, isNot(source.id));

    late Uint8List readBack;
    final processor = ScriptedProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
      (image, context) async {
        readBack = await context.readImage(forgedPath(image, other.path));
        return context.saveImage(bluePng, 'image/png');
      },
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      processors: [processor],
    );

    await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        processorId: 'local.resize',
      ),
    );

    expect(readBack, redPng);
    expect(readBack, isNot(bluePng));
  });

  test('处理器保存的结果可在本次内读回，其它资产仍被拒', () async {
    final source = await store.saveAsset(redPng, 'image/png');
    // 与将被保存的内容不同，否则 store 按 hash 去重后 id 相同，读回其实是自己。
    final other = await store.saveAsset(solidPng(0, 200, 0), 'image/png');

    late Uint8List savedBytes;
    late Object? foreignError;
    final processor = ScriptedProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
      (image, context) async {
        final saved = await context.saveImage(bluePng, 'image/png');
        savedBytes = await context.readImage(saved);
        try {
          await context.readImage(other);
        } on Object catch (failure) {
          foreignError = failure;
        }
        return saved;
      },
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      processors: [processor],
    );

    final result = await registry.process(
      source,
      const ProcessingStep(
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        processorId: 'local.resize',
      ),
    );

    expect(result.id, isNot(source.id));
    expect(savedBytes, bluePng);
    expect(foreignError, isA<PluginException>());
    expect(foreignError.toString(), contains('只能读取本次创建的图片'));
  });

  test('取消发生在保存前：抛 ProcessingCancelled 且不落任何文件', () async {
    final source = await store.saveAsset(redPng, 'image/png');
    int assetFiles() {
      final directory = Directory('${store.root.path}/assets');
      if (!directory.existsSync()) return 0;
      return directory
          .listSync()
          .whereType<File>()
          .where((file) => !file.path.split('/').last.startsWith('.'))
          .length;
    }

    final before = assetFiles();
    final processor = ScriptedProcessor(
      const ProcessorDescriptor(
        id: 'local.resize',
        pluginId: 'builtin.local-tools',
        version: '1.0.0',
        name: '缩放',
      ),
      (image, context) => context.saveImage(bluePng, 'image/png'),
    );
    final registry = PluginRegistry.forTesting(
      store: store,
      processors: [processor],
    );

    await expectLater(
      registry.process(
        source,
        const ProcessingStep(
          pluginId: 'builtin.local-tools',
          version: '1.0.0',
          processorId: 'local.resize',
        ),
        isCancelled: () => true,
      ),
      throwsA(isA<ProcessingCancelled>()),
    );

    expect(processor.error, isA<ProcessingCancelled>());
    expect(assetFiles(), before);
  });

  test('禁用的内置插件拒绝新任务，但注册表仍保留其版本信息', () async {
    final manager = PluginManager(store);
    await manager.setEnabled('builtin.providers', false);
    final registry = await PluginRegistry.load(store);
    addTearDown(registry.dispose);

    expect(registry.providers, isEmpty);
    await expectLater(
      registry.generate(input(config('images')), 'key'),
      emitsError(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('已禁用'),
        ),
      ),
    );

    await manager.setEnabled('builtin.providers', true);
    final enabled = await PluginRegistry.load(store);
    addTearDown(enabled.dispose);
    expect(
      enabled.providers.map((item) => item.id),
      containsAll(['images', 'responses', 'wavespeed', 'evolink']),
    );
  });
}
