import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/providers/provider_detail_page.dart';
import 'package:image_gen/features/providers/providers_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 记录真实 HttpClient 的创建次数：非零即代表检查走了网络。
class _NetworkGuard extends HttpOverrides {
  int clients = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    clients++;
    throw StateError('测试中禁止真实网络请求');
  }
}

class _FakeStore extends StudioStore {
  _FakeStore(
    Database db,
    List<ProviderConfig> initial, {
    this.settingsBroken = false,
    Map<String, String> keys = const {},
  }) : _providers = List.of(initial),
       _keys = {...keys},
       super(db, Directory.systemTemp);

  final List<ProviderConfig> _providers;
  final Map<String, String> _keys;
  final bool settingsBroken;
  final List<String> keyReads = [];

  @override
  Future<List<ProviderConfig>> providers() async => List.of(_providers);

  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async {
    keyReads.add(id);
    return _keys[id];
  }

  @override
  Future<void> saveProvider(ProviderConfig provider, {String? key}) async {}

  @override
  Future<void> deleteProvider(String id) async {
    _providers.removeWhere((item) => item.id == id);
  }

  @override
  Future<Map<String, dynamic>?> setting(String key) async {
    // 模拟插件存储不可用：注册表加载失败，页面没有注册表可用。
    if (settingsBroken && key != 'selection') {
      throw StateError('settings unavailable');
    }
    return null;
  }

  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {}
}

const _acmeDescriptor = ProviderDescriptor(
  id: 'acme.logo',
  pluginId: 'acme.plugin',
  version: '2.1.0',
  name: 'Acme Logo',
  defaultBaseUrl: 'https://acme.example.com/v1',
  defaultModel: 'acme-logo-2',
);

class _RecordingExtension implements ProviderExtension {
  _RecordingExtension(this.descriptor);

  @override
  final ProviderDescriptor descriptor;
  final List<String> models = const ['m-1', 'm-2'];
  final List<String> seenBaseUrls = [];

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
  ) async {
    seenBaseUrls.add(provider.baseUrl);
    return models;
  }

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) =>
      const Stream.empty();

  @override
  void cancel(String taskId) {}
}

ProviderConfig _dynamicProvider({
  String adapterId = 'acme.logo',
  String? adapterVersion,
}) => ProviderConfig(
  id: 'acme-1',
  name: 'Acme 网关',
  baseUrl: 'https://unauthorized.example.com/v1',
  models: const ['acme-logo-2'],
  adapterId: adapterId,
  adapterVersion: adapterVersion,
);

ProviderConfig _legacyProvider({String? adapterVersion}) => ProviderConfig(
  id: 'legacy-1',
  name: '旧内置',
  baseUrl: 'https://legacy.example.com/v1',
  models: const ['gpt-image-1'],
  adapterVersion: adapterVersion,
);

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Database database;
  late _NetworkGuard guard;
  late HttpOverrides? previous;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    previous = HttpOverrides.current;
    guard = _NetworkGuard();
    HttpOverrides.global = guard;
  });

  tearDown(() async {
    HttpOverrides.global = previous;
    await database.close();
  });

  testWidgets('注册表就绪但适配器未安装时不检查连接也不读取密钥', (tester) async {
    final store = _FakeStore(database, [
      _dynamicProvider(adapterId: 'ghost.adapter'),
    ]);
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [_RecordingExtension(_acmeDescriptor)],
    );

    await _pump(tester, ProvidersPage(store: store, registry: registry));
    await tester.tap(find.byKey(const ValueKey('check-acme-1')));
    await tester.pumpAndSettle();

    expect(store.keyReads, isEmpty);
    expect(guard.clients, 0);
    expect(find.textContaining('未安装或未启用'), findsOneWidget);
  });

  testWidgets('注册表就绪时检查连接经实际适配器发现模型', (tester) async {
    final store = _FakeStore(database, [_dynamicProvider()]);
    final extension = _RecordingExtension(_acmeDescriptor);
    final registry = PluginRegistry.forTesting(
      store: store,
      providers: [extension],
    );

    await _pump(tester, ProvidersPage(store: store, registry: registry));
    await tester.tap(find.byKey(const ValueKey('check-acme-1')));
    await tester.pumpAndSettle();

    expect(extension.seenBaseUrls, ['https://unauthorized.example.com/v1']);
    expect(guard.clients, 0);
    expect(find.textContaining('连接正常，共 2 个模型'), findsOneWidget);
  });

  testWidgets('注册表不可用时动态适配器不走旧检查器', (tester) async {
    final store = _FakeStore(
      database,
      [_dynamicProvider()],
      settingsBroken: true,
      keys: const {'acme-1': 'sk-acme'},
    );

    await _pump(tester, ProvidersPage(store: store));
    await tester.tap(find.byKey(const ValueKey('check-acme-1')));
    await tester.pumpAndSettle();

    expect(store.keyReads, isEmpty);
    expect(guard.clients, 0);
    expect(find.textContaining('未安装或未启用'), findsOneWidget);
  });

  testWidgets('注册表不可用时固定版本的旧内置配置也不走旧检查器', (tester) async {
    final store = _FakeStore(database, [
      _legacyProvider(adapterVersion: '1.0.0'),
    ], settingsBroken: true);

    await _pump(tester, ProvidersPage(store: store));
    await tester.tap(find.byKey(const ValueKey('check-legacy-1')));
    await tester.pumpAndSettle();

    expect(store.keyReads, isEmpty);
    expect(guard.clients, 0);
  });

  testWidgets('注册表不可用时未固定版本的旧内置配置仍可兼容检查', (tester) async {
    final store = _FakeStore(
      database,
      [_legacyProvider()],
      settingsBroken: true,
      keys: const {'legacy-1': 'sk-legacy'},
    );

    await _pump(tester, ProvidersPage(store: store));
    await tester.tap(find.byKey(const ValueKey('check-legacy-1')));
    await tester.pumpAndSettle();

    expect(store.keyReads, ['legacy-1']);
    expect(guard.clients, 1);
  });

  testWidgets('详情页在注册表不可用时拒绝动态适配器的模型发现', (tester) async {
    final store = _FakeStore(
      database,
      [_dynamicProvider()],
      settingsBroken: true,
      keys: const {'acme-1': 'sk-acme'},
    );

    await _pump(
      tester,
      ProviderDetailPage(
        store: store,
        provider: _dynamicProvider(),
        showModels: true,
      ),
    );
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();

    expect(store.keyReads, isEmpty);
    expect(guard.clients, 0);
    expect(find.textContaining('未安装或未启用'), findsOneWidget);
  });

  testWidgets('详情页在注册表不可用时保留旧内置配置的兼容发现', (tester) async {
    final store = _FakeStore(
      database,
      [_legacyProvider()],
      settingsBroken: true,
      keys: const {'legacy-1': 'sk-legacy'},
    );

    await _pump(
      tester,
      ProviderDetailPage(
        store: store,
        provider: _legacyProvider(),
        showModels: true,
      ),
    );
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();

    expect(store.keyReads, ['legacy-1']);
    expect(guard.clients, 1);
  });
}
