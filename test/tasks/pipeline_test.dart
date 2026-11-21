import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class KeyStore extends StudioStore {
  KeyStore(super.db, super.root);
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => 'private-test-key';
}

class FakeClient implements GenerationClient {
  final events = StreamController<GenerationEvent>();
  int calls = 0;
  GenerationInput? received;
  @override
  Stream<GenerationEvent> generate(GenerationInput input, String key) {
    calls++;
    received = input;
    return events.stream;
  }

  @override
  void cancel(String taskId) {}
}

class StubProvider implements ProviderExtension {
  @override
  ProviderDescriptor get descriptor => const ProviderDescriptor(
    id: 'p',
    pluginId: 'test',
    version: '1.0.0',
    name: '测试供应商',
  );

  @override
  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  }) => const GenerationCapabilities();

  @override
  Future<GenerationPlan> plan(GenerationInput input) async =>
      GenerationPlan(input: input, expectedCount: input.params.count);

  @override
  Future<List<String>> discoverModels(
    ProviderConfig provider,
    String? apiKey,
  ) async => const [];

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) =>
      const Stream.empty();

  @override
  void cancel(String taskId) {}
}

/// 输出 SVG，避免与 PNG 参考图按哈希去重成同一个资产。
class SvgProcessor implements ImageProcessorExtension {
  SvgProcessor({this.failures = 0});

  int failures;
  int calls = 0;

  @override
  ProcessorDescriptor get descriptor => const ProcessorDescriptor(
    id: 'test.svg',
    pluginId: 'test',
    version: '1.0.0',
    name: '转 SVG',
  );

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    calls++;
    if (failures > 0) {
      failures--;
      throw const FormatException('后处理失败');
    }
    final bytes = await context.readImage(image);
    final svg = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${bytes.length + 1}" height="1"><rect width="1" height="1"/></svg>',
    );
    return context.saveImage(Uint8List.fromList(svg), 'image/svg+xml');
  }
}

/// 链上的普通处理器；按失败次数模拟中途中断。
class ChainProcessor implements ImageProcessorExtension {
  ChainProcessor(this.name, {this.failures = 0});

  final String name;
  int failures;
  int calls = 0;

  @override
  ProcessorDescriptor get descriptor => ProcessorDescriptor(
    id: 'test.$name',
    pluginId: 'test',
    version: '1.0.0',
    name: name,
  );

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    calls++;
    if (failures > 0) {
      failures--;
      throw FormatException('$name 失败');
    }
    final bytes = await context.readImage(image);
    final svg = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${bytes.length + calls}" height="1"/>',
    );
    return context.saveImage(Uint8List.fromList(svg), 'image/svg+xml');
  }
}

/// 卡在预处理里，用来验证取消后不会再发出收费请求。
class BlockingProcessor implements ImageProcessorExtension {
  final gate = Completer<void>();
  int calls = 0;

  @override
  ProcessorDescriptor get descriptor => const ProcessorDescriptor(
    id: 'test.block',
    pluginId: 'test',
    version: '1.0.0',
    name: '阻塞处理',
  );

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    calls++;
    await gate.future;
    final bytes = await context.readImage(image);
    final svg = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="${bytes.length + 5}" height="1"/>',
    );
    return context.saveImage(Uint8List.fromList(svg), 'image/svg+xml');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  late FakeClient client;
  late SvgProcessor processor;
  late PluginRegistry plugins;
  late TaskRunner runner;
  // 派生任务也在这张表里，按 id 取主任务更稳。
  Future<StudioTask> mainTask() async =>
      (await store.tasks()).firstWhere((task) => task.id == 't');
  const provider = ProviderConfig(
    id: 'p',
    name: '测试',
    baseUrl: 'https://example.com/v1',
    // 与注册表里的测试适配器对齐，避免走内置 images 路由。
    adapterId: 'p',
  );
  const step = ProcessingStep(
    pluginId: 'test',
    version: '1.0.0',
    processorId: 'test.svg',
  );
  final image = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    ),
  );
  // 第二张图内容不同，避免按哈希去重成同一张原图。
  final secondImage = Uint8List.fromList(
    img.encodePng(
      img.Image(width: 1, height: 1)..setPixelRgb(0, 0, 200, 30, 30),
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pipeline-');
    final opened = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: directory,
    );
    store = KeyStore(opened.db, opened.root);
    await store.saveProvider(provider);
    client = FakeClient();
    processor = SvgProcessor();
    plugins = PluginRegistry.forTesting(
      store: store,
      providers: [StubProvider()],
      processors: [processor],
    );
    runner = TaskRunner(store, client, plugins: plugins);
  });

  tearDown(() async {
    await plugins.dispose();
    await store.close();
    await directory.delete(recursive: true);
  });

  test('前处理只改本次输入，原参考图保留', () async {
    final source = await store.saveAsset(image, 'image/png');
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        references: [source],
        preprocessors: const [step],
      ),
    );

    final running = runner.drain();
    await pumpEventQueue();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    await client.events.close();
    await running;

    final received = client.received!;
    expect(received.preprocessors, isEmpty);
    expect(received.references.single.id, isNot(source.id));
    expect(processor.calls, 1);
    final task = await mainTask();
    expect(task.status, TaskStatus.done);
    expect(task.input.preprocessors, hasLength(1));
    expect(await store.asset(source.id), isNotNull);
  });

  test('前处理失败时不调用供应商生成', () async {
    final source = await store.saveAsset(image, 'image/png');
    processor.failures = 1;
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        references: [source],
        preprocessors: const [step],
      ),
    );

    await runner.drain();

    final task = await mainTask();
    expect(task.status, TaskStatus.error);
    expect(task.error, contains('后处理失败'));
    expect(client.calls, 0);
  });

  test('后处理失败可只重试本地处理', () async {
    final source = await store.saveAsset(image, 'image/png');
    processor.failures = 1;
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        references: [source],
        postprocessors: const [step],
      ),
    );

    final first = runner.drain();
    await pumpEventQueue();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    await client.events.close();
    await first;

    expect(client.calls, 1);
    var task = await mainTask();
    expect(task.status, TaskStatus.partialError);
    final failure = await store.pipelineFailure('t');
    expect(failure, isNotNull);
    expect(failure!.stage, 'postprocess');
    expect(failure.sourceAssetId, isNotNull);

    await store.retryTask('t');
    await runner.drain();

    expect(client.calls, 1);
    expect(processor.calls, 2);
    task = await mainTask();
    expect(task.status, TaskStatus.done);
    expect(await store.pipelineFailure('t'), isNull);
    final derived = (await store.tasks())
        .where((t) => t.input.provider.id.startsWith('local.'))
        .toList();
    expect(derived, hasLength(1));
    expect(derived.single.input.parentTaskId, 't');
  });

  test('派生资产登记可复用且不冒充供应商', () async {
    final source = await store.saveAsset(image, 'image/png');
    final result = await store.saveAsset(
      Uint8List.fromList(
        utf8.encode(
          '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"></svg>',
        ),
      ),
      'image/svg+xml',
    );

    final first = await store.recordDerivedImage(
      source: source,
      result: result,
      step: step,
    );
    final second = await store.recordDerivedImage(
      source: source,
      result: result,
      step: step,
    );
    expect(first, second);

    final derived = (await store.tasks()).single;
    expect(derived.id, first);
    expect(derived.status, TaskStatus.done);
    expect(derived.input.provider.id, 'local.test');
    expect(derived.input.provider.baseUrl, isNot(contains('http')));
    expect(derived.input.parentTaskId, isNull);
    expect(derived.input.parentAssetId, source.id);
    expect(derived.outputs.single.id, result.id);
    expect(() => store.retryTask(first), throwsA(isA<StateError>()));
  });
  test('多图多步骤失败停在断点，重试跳过已完成图', () async {
    final first = ChainProcessor('a');
    final second = ChainProcessor('b', failures: 1);
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [StubProvider()],
      processors: [first, second],
    );
    addTearDown(registry.dispose);
    final local = TaskRunner(store, client, plugins: registry);
    const stepA = ProcessingStep(
      pluginId: 'test',
      version: '1.0.0',
      processorId: 'test.a',
    );
    const stepB = ProcessingStep(
      pluginId: 'test',
      version: '1.0.0',
      processorId: 'test.b',
    );
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 2),
        postprocessors: const [stepA, stepB],
      ),
    );

    final running = local.drain();
    await pumpEventQueue();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    client.events.add(GenerationEvent('image', bytes: secondImage, key: 'two'));
    await client.events.close();
    await running;

    var task = await mainTask();
    expect(task.status, TaskStatus.partialError);
    final failure = await store.pipelineFailure('t');
    expect(failure!.position, 0);
    expect(failure.step, 1);
    expect(failure.attempt, 1);
    expect(failure.expected, 2);
    expect(failure.sourceAssetId, isNotNull);
    // 第一张第 2 步失败后不再开始第二张。
    expect(first.calls, 1);
    expect(second.calls, 1);
    expect(client.calls, 1);

    await store.retryTask('t');
    await local.drain();

    expect(client.calls, 1);
    // 已完成的第一张第 1 步不重跑，只补失败步骤与第二张。
    expect(first.calls, 2);
    expect(second.calls, 3);
    task = await mainTask();
    expect(task.status, TaskStatus.done);
    expect(await store.pipelineFailure('t'), isNull);
    final derived = (await store.tasks()).where(
      (t) => t.input.provider.id == 'local.test',
    );
    expect(derived, hasLength(4));
  });

  test('预处理期间取消后不再调用生成', () async {
    final blocked = BlockingProcessor();
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [StubProvider()],
      processors: [blocked],
    );
    addTearDown(registry.dispose);
    final local = TaskRunner(store, client, plugins: registry);
    final source = await store.saveAsset(image, 'image/png');
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        references: [source],
        preprocessors: const [
          ProcessingStep(
            pluginId: 'test',
            version: '1.0.0',
            processorId: 'test.block',
          ),
        ],
      ),
    );

    final running = local.drain();
    // 等预处理真正进入处理器：数据库访问跨 isolate，单纯排队事件不够。
    for (var i = 0; i < 100 && blocked.calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(blocked.calls, 1);
    await local.cancel('t');
    blocked.gate.complete();
    await running;

    expect(client.calls, 0);
    expect((await store.tasks()).single.status, TaskStatus.aborted);
  });

  test('连续两次处理失败后仍从原图重试，第三次成功', () async {
    processor.failures = 2;
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        postprocessors: const [step],
      ),
    );

    final first = runner.drain();
    await pumpEventQueue();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    await client.events.close();
    await first;

    expect(client.calls, 1);
    var failure = await store.pipelineFailure('t');
    expect(failure!.attempt, 1);

    await store.retryTask('t');
    await runner.drain();
    expect(client.calls, 1);
    failure = await store.pipelineFailure('t');
    expect(failure, isNotNull);
    // 重试不会改写断点里的生图尝试，否则下一次会读不到原图。
    expect(failure!.attempt, 1);
    expect(await store.attemptOutputs('t', failure.attempt), hasLength(1));

    await store.retryTask('t');
    await runner.drain();
    expect(client.calls, 1);
    final task = await mainTask();
    expect(task.status, TaskStatus.done);
    expect(await store.pipelineFailure('t'), isNull);
  });

  test('本地处理重试不改写收费原图数量', () async {
    processor.failures = 1;
    await store.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 2),
        postprocessors: const [step],
      ),
    );

    final first = runner.drain();
    await pumpEventQueue();
    client.events.add(GenerationEvent('image', bytes: image, key: 'one'));
    await client.events.close();
    await first;

    expect(client.calls, 1);
    var task = await mainTask();
    expect(task.status, TaskStatus.partialError);
    final failure = await store.pipelineFailure('t');
    expect(failure!.expected, 2);

    await store.retryTask('t');
    await runner.drain();

    expect(client.calls, 1);
    task = await mainTask();
    expect(task.status, TaskStatus.partialError);
    expect(task.error, contains('1/2'));
    expect(await store.pipelineFailure('t'), isNull);
  });
}
