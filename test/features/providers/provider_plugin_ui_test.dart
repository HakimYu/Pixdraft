import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/providers/provider_detail_page.dart';
import 'package:image_gen/features/providers/provider_editor_page.dart';
import 'package:image_gen/features/providers/providers_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/builtin_providers.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:image_gen/plugins/plugin_registry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeStore extends StudioStore {
  _FakeStore(
    Database db,
    List<ProviderConfig> initial, {
    Map<String, String> keys = const {},
  }) : _providers = List.of(initial),
       _keys = {...keys},
       super(db, Directory.systemTemp);

  final List<ProviderConfig> _providers;
  final Map<String, String> _keys;

  final List<ProviderConfig> saved = [];
  final List<String?> savedKeys = [];

  @override
  Future<List<ProviderConfig>> providers() async => List.of(_providers);

  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => _keys[id];

  @override
  Future<void> saveProvider(ProviderConfig provider, {String? key}) async {
    saved.add(provider);
    savedKeys.add(key);
    final index = _providers.indexWhere((item) => item.id == provider.id);
    if (index < 0) {
      _providers.add(provider);
    } else {
      _providers[index] = provider;
    }
    if (key != null) _keys[provider.id] = key;
  }

  @override
  Future<void> deleteProvider(String id) async {
    _providers.removeWhere((item) => item.id == id);
    _keys.remove(id);
  }

  @override
  Future<Map<String, dynamic>?> setting(String key) async => null;

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
  fields: [
    PluginField(
      key: 'style',
      label: '风格',
      type: 'select',
      defaultValue: 'flat',
      options: ['flat', '3d'],
    ),
  ],
);

class _FakeExtension implements ProviderExtension {
  _FakeExtension(this.descriptor, {this.models = const []});

  @override
  final ProviderDescriptor descriptor;
  final List<String> models;

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
  ) async => models;

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) =>
      const Stream.empty();

  @override
  void cancel(String taskId) {}
}

class _Launcher extends StatelessWidget {
  const _Launcher({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const ValueKey('openPage'),
        onPressed: () =>
            Navigator.of(context).push(MaterialPageRoute<void>(builder: builder)),
        child: const Text('打开'),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

/// 编辑器保存后会 pop，所以从宿主页面压栈进入。
Future<void> _pumpEditor(
  WidgetTester tester,
  WidgetBuilder builder,
) async {
  await _pump(tester, _Launcher(builder: builder));
  await tester.tap(find.byKey(const ValueKey('openPage')));
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.enterText(finder, value);
  await tester.pump();
}

ProviderConfig _provider({
  String id = 'p1',
  String adapterId = 'images',
  String? adapterVersion,
  Map<String, dynamic> pluginConfig = const {},
  String baseUrl = 'https://api.example.com/v1',
}) => ProviderConfig(
  id: id,
  name: '示例供应商 $id',
  baseUrl: baseUrl,
  adapterId: adapterId,
  adapterVersion: adapterVersion,
  pluginConfig: pluginConfig,
);

void main() {
  late Database database;
  late PluginRegistry registry;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });

  tearDown(() async {
    await database.close();
  });

  PluginRegistry buildRegistry(StudioStore target) {
    registry = PluginRegistry.forTesting(
      store: target,
      providers: [
        ...createBuiltinProviders(target),
        _FakeExtension(_acmeDescriptor, models: const ['m-1', 'm-2']),
      ],
    );
    return registry;
  }

  testWidgets('供应商列表显示插件描述名称，未知适配器给出提示', (tester) async {
    final target = _FakeStore(database, [
      _provider(id: 'p1'),
      _provider(id: 'p2', adapterId: 'ghost.adapter'),
    ]);
    await _pump(
      tester,
      ProvidersPage(store: target, registry: buildRegistry(target)),
    );

    expect(find.text('OpenAI Images'), findsOneWidget);
    expect(find.text('插件未安装：ghost.adapter'), findsOneWidget);
  });

  testWidgets('独立适配器渲染插件字段并保存 adapterId/version/pluginConfig', (tester) async {
    final initial = _provider(
      adapterId: 'acme.logo',
      adapterVersion: '2.1.0',
      pluginConfig: const {'style': '3d'},
    );
    final target = _FakeStore(database, [initial]);
    buildRegistry(target);

    await _pumpEditor(
      tester,
      (_) => ProviderEditorPage(
        store: target,
        provider: initial,
        registry: registry,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('风格'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('插件参数'), findsOneWidget);
    expect(find.text('风格'), findsOneWidget);
    expect(find.byKey(const ValueKey('providerProtocol')), findsNothing);

    await _tapKey(tester, 'providerSaveButton');

    final saved = target.saved.single;
    expect(saved.adapterId, 'acme.logo');
    expect(saved.adapterVersion, '2.1.0');
    expect(saved.pluginConfig['style'], '3d');
  });

  testWidgets('新增时选择独立适配器后保存默认地址与适配器身份', (tester) async {
    final target = _FakeStore(database, const []);
    buildRegistry(target);

    await _pumpEditor(
      tester,
      (_) => ProviderEditorPage(store: target, registry: registry),
    );

    await _enter(tester, 'providerName', '我的插件供应商');
    await _tapKey(tester, 'providerAdapter');
    await tester.tap(find.text('Acme Logo（acme.plugin v2.1.0）').last);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'providerSaveButton');

    final saved = target.saved.single;
    expect(saved.adapterId, 'acme.logo');
    expect(saved.adapterVersion, '2.1.0');
    expect(saved.baseUrl, 'https://acme.example.com/v1');
    expect(saved.pluginConfig['style'], 'flat');
  });

  testWidgets('更改主机后必须重新填写密钥', (tester) async {
    final initial = _provider();
    final target = _FakeStore(database, [initial], keys: {'p1': 'sk-old'});
    buildRegistry(target);

    await _pumpEditor(
      tester,
      (_) => ProviderEditorPage(
        store: target,
        provider: initial,
        registry: registry,
      ),
    );

    await _enter(tester, 'providerBaseUrl', 'https://other.example.com/v1');
    await _tapKey(tester, 'providerSaveButton');

    expect(find.textContaining('主机已更改'), findsOneWidget);
    expect(target.saved, isEmpty);

    await _enter(tester, 'providerApiKey', 'sk-new');
    await _tapKey(tester, 'providerSaveButton');
    expect(target.savedKeys.single, 'sk-new');
  });

  testWidgets('切换内置协议时同步 adapterId 与默认地址', (tester) async {
    final target = _FakeStore(database, const []);
    buildRegistry(target);

    await _pumpEditor(
      tester,
      (_) => ProviderEditorPage(store: target, registry: registry),
    );

    await _enter(tester, 'providerName', '内置协议供应商');
    await _tapKey(tester, 'providerProtocol');
    await tester.tap(find.text('WaveSpeed').last);
    await tester.pumpAndSettle();
    await _tapKey(tester, 'providerSaveButton');

    final saved = target.saved.single;
    expect(saved.protocol, ApiProtocol.wavespeed);
    expect(saved.adapterId, 'wavespeed');
    expect(saved.baseUrl, 'https://api.wavespeed.ai/api/v3');
  });

  testWidgets('详情页通过插件适配器发现模型', (tester) async {
    final initial = _provider(adapterId: 'acme.logo', adapterVersion: '2.1.0');
    final target = _FakeStore(database, [initial]);
    buildRegistry(target);

    await _pump(
      tester,
      ProviderDetailPage(
        store: target,
        provider: initial,
        registry: registry,
        showModels: true,
      ),
    );

    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();

    expect(
      find.text('已获取 2 个模型；仅查询了模型列表，未发起生图请求。'),
      findsOneWidget,
    );
    expect(find.text('m-1'), findsOneWidget);
  });
}