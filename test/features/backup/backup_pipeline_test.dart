import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/backup/backup_service.dart';
import 'package:image_gen/features/backup/backup_options.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:image_gen/tasks/task_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  ),
);

final svg = Uint8List.fromList(
  utf8.encode(
    '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><rect width="1" height="1"/></svg>',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureValues = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureChannel, (call) async {
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        switch (call.method) {
          case 'read':
            return secureValues[args['key']];
          case 'write':
            secureValues[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secureValues.remove(args['key']);
            return null;
          case 'readAll':
            return Map<String, String>.from(secureValues);
          case 'deleteAll':
            secureValues.clear();
            return null;
          case 'containsKey':
            return secureValues.containsKey(args['key']);
        }
        return null;
      });
  sqfliteFfiInit();
  late Directory a;
  late Directory b;
  late StudioStore source;
  late StudioStore target;

  setUp(() async {
    a = await Directory.systemTemp.createTemp('backup-a-');
    b = await Directory.systemTemp.createTemp('backup-b-');
    source = await StudioStore.open(factory: databaseFactoryFfi, directory: a);
    target = await StudioStore.open(factory: databaseFactoryFfi, directory: b);
  });

  tearDown(() async {
    await source.close();
    await target.close();
    await a.delete(recursive: true);
    await b.delete(recursive: true);
  });

  test('备份保留插件字段、处理链与参数内资产引用', () async {
    const provider = ProviderConfig(
      id: 'p',
      name: '插件供应商',
      baseUrl: 'https://api.example.com/v1',
      adapterId: 'test.script',
      adapterVersion: '2.0.0',
      pluginConfig: {'region': 'cn'},
    );
    await source.saveProvider(provider);
    final reference = await source.saveAsset(png, 'image/png');
    final mask = await source.saveAsset(svg, 'image/svg+xml');
    final step = ProcessingStep(
      pluginId: 'test.script',
      version: '2.0.0',
      processorId: 'test.svg',
      params: {'source': reference.toJson(), 'strength': 0.5},
    );
    await source.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1, extra: {'seed': 7}),
        references: [reference],
        mask: mask,
        preprocessors: [step],
        postprocessors: [step],
      ),
    );
    await source.transition('t', TaskStatus.queued, TaskStatus.done);

    final zip = (await BackupService(source).exportWebBackup(options: BackupOptions(trash: true))).bytes;
    final result = await BackupService(target).importBackup(zip);
    expect(result.preview.tasks, 1);

    final task = (await target.tasks()).single;
    expect(task.input.provider.adapterId, 'test.script');
    expect(task.input.provider.adapterVersion, '2.0.0');
    expect(task.input.provider.pluginConfig, {'region': 'cn'});
    expect(task.input.params.extra, {'seed': 7});
    expect(task.input.preprocessors, hasLength(1));
    expect(task.input.postprocessors, hasLength(1));
    final params = task.input.preprocessors.single.params;
    expect(params['strength'], 0.5);
    final remapped = params['source'] as Map<String, dynamic>;
    expect(await target.asset(remapped['id'] as String), isNotNull);

    // 目标库没有安装插件，只提示不阻断历史任务读取。
    expect(
      result.preview.warnings.any(
        (warning) => warning.contains('test.script@2.0.0'),
      ),
      isTrue,
    );
  });

  test('派生资产关系可以导出并恢复', () async {
    final provider = const ProviderConfig(
      id: 'p',
      name: '测试',
      baseUrl: 'https://api.example.com/v1',
    );
    await source.saveProvider(provider);
    final asset = await source.saveAsset(png, 'image/png');
    final derived = await source.saveAsset(svg, 'image/svg+xml');
    final step = const ProcessingStep(
      pluginId: 'test',
      version: '1.0.0',
      processorId: 'test.svg',
    );
    final taskId = await source.recordDerivedImage(
      source: asset,
      result: derived,
      step: step,
    );

    final zip = (await BackupService(source).exportWebBackup(options: BackupOptions(trash: true))).bytes;
    await BackupService(target).importBackup(zip);

    final task = (await target.tasks()).single;
    expect(task.id, taskId);
    expect(task.input.parentAssetId, asset.id);
    expect(task.outputs.single.id, derived.id);
  });

  test('处理断点随备份恢复，重试只跑本地处理', () async {
    const provider = ProviderConfig(
      id: 'p',
      name: '插件供应商',
      baseUrl: 'https://api.example.com/v1',
      adapterId: 'test.script',
      adapterVersion: '2.0.0',
    );
    await source.saveProvider(provider);
    final raw = await source.saveAsset(png, 'image/png');
    const step = ProcessingStep(
      pluginId: 'test',
      version: '1.0.0',
      processorId: 'test.svg',
    );
    await source.enqueue(
      GenerationInput(
        taskId: 't',
        provider: provider,
        prompt: '猫',
        params: const GenerationParams(count: 1),
        postprocessors: const [step],
      ),
    );
    await source.startAttempt('t');
    await source.attachOutput('t', raw, 1, 0, requireRunning: true);
    await source.savePipelineState(
      't',
      stage: 'postprocess',
      position: 0,
      attempt: 1,
      step: 0,
      expected: 1,
      message: '后处理失败',
    );
    await source.transition(
      't',
      TaskStatus.running,
      TaskStatus.partialError,
      error: '后处理失败',
    );

    final zip = (await BackupService(source).exportWebBackup(options: BackupOptions(trash: true))).bytes;
    await BackupService(target).importBackup(zip);

    final imported = (await target.tasks()).firstWhere(
      (task) => task.id == 't',
    );
    expect(imported.status, TaskStatus.partialError);
    final failure = await target.pipelineFailure('t');
    expect(failure?.attempt, 1);
    expect(failure?.expected, 1);
    expect(failure?.stage, 'postprocess');
    expect(await target.attemptOutputs('t', 1), hasLength(1));

    // 连续两次本地处理失败仍保留同一断点，第三次成功；全程不重新生成。
    final processor = _SvgProcessor(failures: 2);
    final registry = PluginRegistry.forTesting(
      store: target,
      processors: [processor],
    );
    addTearDown(registry.dispose);
    final client = _NoClient();
    final runner = TaskRunner(target, client, plugins: registry);

    await target.retryTask('t');
    await runner.drain();
    expect(
      (await target.tasks()).firstWhere((task) => task.id == 't').status,
      TaskStatus.partialError,
    );
    expect((await target.pipelineFailure('t'))?.attempt, 1);

    await target.retryTask('t');
    await runner.drain();
    expect(
      (await target.tasks()).firstWhere((task) => task.id == 't').status,
      TaskStatus.partialError,
    );
    expect((await target.pipelineFailure('t'))?.attempt, 1);

    await target.retryTask('t');
    await runner.drain();
    final done = (await target.tasks()).firstWhere((task) => task.id == 't');
    expect(done.status, TaskStatus.done);
    expect(await target.pipelineFailure('t'), isNull);
    expect(await target.attemptOutputs('t', 1), hasLength(1));
    expect(client.calls, 0);
    final derived = (await target.tasks()).where(
      (task) => task.input.provider.id == 'local.test',
    );
    expect(derived, hasLength(1));
  });

  test('派生任务保存完整处理步骤快照并可备份恢复', () async {
    final asset = await source.saveAsset(png, 'image/png');
    final derived = await source.saveAsset(svg, 'image/svg+xml');
    const step = ProcessingStep(
      pluginId: 'test',
      version: '1.0.0',
      processorId: 'test.svg',
      params: {'strength': 0.5, 'label': '手写'},
    );
    await source.recordDerivedImage(source: asset, result: derived, step: step);

    final written = (await source.tasks()).single;
    final snapshot =
        written.input.provider.pluginConfig['step'] as Map<String, dynamic>;
    expect(snapshot['version'], '1.0.0');
    expect(snapshot['params'], {'strength': 0.5, 'label': '手写'});

    final zip = (await BackupService(source).exportWebBackup(options: BackupOptions(trash: true))).bytes;
    await BackupService(target).importBackup(zip);

    final restored = (await target.tasks()).single;
    final restoredStep =
        restored.input.provider.pluginConfig['step'] as Map<String, dynamic>;
    expect(restoredStep['processorId'], 'test.svg');
    expect(restoredStep['params'], {'strength': 0.5, 'label': '手写'});
    expect(restored.input.parentAssetId, asset.id);
    expect(restored.outputs.single.id, derived.id);
  });

  test('备份不带插件安装索引，目标机停用状态不被改写', () async {
    await source.saveSetting(pluginIndexKey, {
      'plugins': {
        'test.script': {'enabled': true, 'name': '脚本供应商'},
      },
    });
    await target.saveSetting(pluginIndexKey, {
      'plugins': {
        'test.script': {'enabled': false, 'name': '脚本供应商'},
      },
    });

    final zip = (await BackupService(source).exportWebBackup(options: BackupOptions(trash: true))).bytes;
    await BackupService(target).importBackup(zip);

    final index = await target.setting(pluginIndexKey);
    expect(index?['plugins']?['test.script']?['enabled'], isFalse);
  });
}

class _SvgProcessor implements ImageProcessorExtension {
  _SvgProcessor({this.failures = 0});

  int failures;
  int calls = 0;

  @override
  ProcessorDescriptor get descriptor => const ProcessorDescriptor(
    id: 'test.svg',
    pluginId: 'test',
    version: '1.0.0',
    name: 'SVG',
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
      throw StateError('处理失败');
    }
    return context.saveImage(svg, 'image/svg+xml');
  }
}

class _NoClient implements GenerationClient {
  int calls = 0;

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) {
    calls++;
    return const Stream.empty();
  }

  @override
  void cancel(String taskId) {}
}
