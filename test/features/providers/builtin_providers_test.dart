import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/builtin_providers.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../api/support.dart';

class _Store extends StudioStore {
  _Store(Database db) : super(db, Directory.systemTemp);
}

void main() {
  late Database database;
  late _Store store;
  late List<ProviderExtension> providers;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await setUpApiFiles();
  });

  tearDownAll(tearDownApiFiles);

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    store = _Store(database);
    providers = createBuiltinProviders(store);
  });

  tearDown(() async {
    await database.close();
  });

  ProviderExtension extensionOf(String id) =>
      providers.firstWhere((item) => item.descriptor.id == id);

  group('内置 adapter 描述', () {
    test('四个稳定 extension ID、pluginId 与版本', () {
      expect(providers.map((item) => item.descriptor.id), [
        'images',
        'responses',
        'wavespeed',
        'evolink',
      ]);
      for (final item in providers) {
        expect(item.descriptor.pluginId, builtinProvidersPluginId);
        expect(item.descriptor.version, '1.0.0');
        expect(item.descriptor.defaultBaseUrl, isNotEmpty);
        expect(item.descriptor.defaultModel, isNotEmpty);
      }
      expect(builtinProvidersPluginId, 'builtin.providers');
    });
  });

  group('capabilities 描述协议能力', () {
    test('Responses 支持蒙版、拒绝标注，并声明预览与文件上传能力', () {
      final caps = extensionOf('responses').capabilities(
        testProvider(protocol: ApiProtocol.responses),
      );
      expect(caps.supportsMask, isTrue);
      expect(caps.supportsMarkup, isFalse);
      expect(caps.supportsPreview, isTrue);
      expect(caps.supportsFileInput, isTrue);
      expect(caps.usesResponseModel, isTrue);
      expect(caps.maxReferences, 16);
    });

    test('能力不随供应商开关关闭：fileInput=false、partialImages=0 仍声明支持', () {
      final caps = extensionOf('responses').capabilities(
        ProviderConfig(
          id: 'p',
          name: 'p',
          baseUrl: 'https://api.example.test/v1',
          protocol: ApiProtocol.responses,
          partialImages: 0,
        ),
      );
      expect(caps.supportsPreview, isTrue);
      expect(caps.supportsFileInput, isTrue);
    });

    test('Images 支持蒙版与标注，预览可用', () {
      final caps = extensionOf('images').capabilities(testProvider());
      expect(caps.supportsMask, isTrue);
      expect(caps.supportsMarkup, isTrue);
      expect(caps.supportsPreview, isTrue);
      expect(caps.usesResponseModel, isFalse);
    });

    test('异步协议用宽高比、无蒙版标注与预览', () {
      for (final item in providers.where(
        (item) => item.descriptor.pluginId == builtinProvidersPluginId,
      )) {
        final async =
            item.descriptor.id == 'wavespeed' || item.descriptor.id == 'evolink';
        final caps = item.capabilities(
          ProviderConfig(
            id: 'p',
            name: 'p',
            baseUrl: 'https://api.example.test',
            protocol: item.descriptor.id == 'wavespeed'
                ? ApiProtocol.wavespeed
                : ApiProtocol.evolink,
            imageModel: item.descriptor.defaultModel,
          ),
        );
        if (!async) continue;
        expect(caps.maxReferences, 10);
        expect(caps.supportsMask, isFalse);
        expect(caps.supportsMarkup, isFalse);
        expect(caps.supportsPreview, isFalse);
        expect(caps.supportsCustomSize, item.descriptor.id == 'evolink');
        expect(caps.formats, ['png', 'jpeg']);
        expect(caps.qualities, ['auto', '1K', '1.5K', '2K']);
        expect(caps.sizes, isNotEmpty);
      }
    });
  });

  group('plan', () {
    test('按 adapterId 规范 protocol，归一化参数并保留额外参数', () async {
      final provider = ProviderConfig.fromJson({
        ...testProvider(
          protocol: ApiProtocol.images,
          transport: TransportMode.json,
        ).toJson(),
        'adapterId': 'responses',
        'adapterVersion': '1.0.0',
        'pluginConfig': {'seed': 7},
      });
      final plan = await extensionOf('responses').plan(
        testInput(
          provider: provider,
          prompt: '重绘',
          params: const GenerationParams(
            size: '1000x1000',
            quality: 'xhigh',
            extra: {'steps': 4},
          ),
          references: [referenceAsset()],
        ),
      );

      expect(plan.input.provider.protocol, ApiProtocol.responses);
      expect(plan.input.provider.adapterId, 'responses');
      expect(plan.input.provider.pluginConfig, {'seed': 7});
      expect(plan.input.params.extra, {'steps': 4});
      expect(plan.input.params.quality, 'high');
      expect(plan.input.params.size, '1008x1008');
      expect(plan.expectedCount, 1);
      expect(plan.metadata['adapterId'], 'responses');
    });

    test('异步协议保留宽高比，并把真实数量交给 runner', () async {
      final plan = await extensionOf('wavespeed').plan(
        testInput(
          provider: testProvider(protocol: ApiProtocol.wavespeed, imageModel: 'bytedance/seedream-v5.5'),
          prompt: '一只猫',
          params: const GenerationParams(
            size: '16:9',
            quality: '2K',
            count: 3,
          ),
        ),
      );
      expect(plan.input.params.size, '16:9');
      expect(plan.input.params.quality, '2K');
      expect(plan.expectedCount, 3);
    });

    test('数量与参考图越界、异步蒙版都在 plan 阶段拒绝', () async {
      Future<void> expectPlanError(
        ProviderExtension extension,
        GenerationInput input,
        String message,
      ) async {
        await expectLater(
          extension.plan(input),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              message,
            ),
          ),
        );
      }

      final images = extensionOf('images');
      final wavespeed = extensionOf('wavespeed');
      await expectPlanError(
        images,
        testInput(
          provider: testProvider(),
          prompt: 'x',
          params: const GenerationParams(count: 0),
        ),
        '生成数量需为 1–10',
      );
      await expectPlanError(
        images,
        testInput(
          provider: testProvider(),
          prompt: 'x',
          references: List.filled(17, referenceAsset()),
        ),
        '参考图最多 16 张',
      );
      await expectPlanError(
        wavespeed,
        testInput(
          provider: testProvider(protocol: ApiProtocol.wavespeed, imageModel: 'bytedance/seedream-v5.5/edit'),
          prompt: 'x',
          references: List.filled(11, referenceAsset()),
        ),
        '当前模型最多支持 10 张参考图',
      );
      await expectPlanError(
        wavespeed,
        testInput(
          provider: testProvider(protocol: ApiProtocol.wavespeed, imageModel: 'bytedance/seedream-v5.5/edit'),
          prompt: 'x',
          references: [referenceAsset()],
          mask: maskAsset(),
        ),
        '当前模型的蒙版需要受支持的参考图编辑模式',
      );
    });
  });

  group('generate 以 adapterId 为权威路由', () {
    test('adapterId=responses 而 protocol=images 时仍请求 /responses', () async {
      final adapter = FakeAdapter(
        (options, cancelFuture) async => jsonBody({
          'output': [
            {
              'type': 'image_generation_call',
              'id': 'img_1',
              'output_index': 0,
              'result': b64(samplePng),
            },
          ],
        }),
      );
      final routed = BuiltinProvider(
        descriptor: responsesDescriptor,
        protocol: ApiProtocol.responses,
        store: store,
        dio: fakeDio(adapter),
      );
      final provider = ProviderConfig.fromJson({
        ...testProvider(
          protocol: ApiProtocol.images,
          transport: TransportMode.json,
        ).toJson(),
        'adapterId': 'responses',
      });

      final result = await drain(
        routed.generate(
          testInput(provider: provider, prompt: '重绘'),
          'key',
        ),
      );

      expect(result.error, isNull);
      expect(adapter.requests.single.uri.path, '/v1/responses');
      expect(result.ofKind('image'), hasLength(1));
    });

    test('adapterId=images 而 protocol=responses 时仍请求 /images/generations', () async {
      final adapter = FakeAdapter(
        (options, cancelFuture) async => jsonBody({
          'data': [
            {'b64_json': b64(samplePng)},
          ],
        }),
      );
      final routed = BuiltinProvider(
        descriptor: imagesDescriptor,
        protocol: ApiProtocol.images,
        store: store,
        dio: fakeDio(adapter),
      );
      final provider = ProviderConfig.fromJson({
        ...testProvider(
          protocol: ApiProtocol.responses,
          transport: TransportMode.json,
        ).toJson(),
        'adapterId': 'images',
      });

      final result = await drain(
        routed.generate(
          testInput(provider: provider, prompt: '一只猫'),
          'key',
        ),
      );

      expect(result.error, isNull);
      expect(adapter.requests.single.uri.path, '/v1/images/generations');
      expect(result.ofKind('image'), hasLength(1));
    });
  });

  group('discoverModels 复用无收费检查', () {
    BuiltinProvider probe(FakeAdapter adapter) => BuiltinProvider(
      descriptor: imagesDescriptor,
      protocol: ApiProtocol.images,
      store: store,
      dio: fakeDio(adapter),
    );

    test('返回模型列表', () async {
      final adapter = FakeAdapter(
        (options, cancelFuture) async => jsonBody({
          'data': [
            {'id': 'gpt-image-1'},
            {'id': 'gpt-image-1.5'},
          ],
        }),
      );
      final models = await probe(adapter).discoverModels(testProvider(), 'key');
      expect(models, ['gpt-image-1', 'gpt-image-1.5']);
      expect(adapter.requests.single.uri.path, '/v1/models');
    });

    test('没有 /models 端点时返回空表，保留手工输入', () async {
      final adapter = FakeAdapter(
        (options, cancelFuture) async => errorBody(404, 'not found'),
      );
      final models = await probe(adapter).discoverModels(testProvider(), null);
      expect(models, isEmpty);
    });

    test('鉴权失败抛出检查消息', () async {
      final adapter = FakeAdapter(
        (options, cancelFuture) async => errorBody(401, 'unauthorized'),
      );
      await expectLater(
        probe(adapter).discoverModels(testProvider(), 'bad'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('密钥无效'),
          ),
        ),
      );
    });
  });
}
