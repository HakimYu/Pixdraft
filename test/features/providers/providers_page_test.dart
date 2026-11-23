import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/providers/providers_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeStore extends StudioStore {
  _FakeStore(
    Database db,
    List<ProviderConfig> initial, {
    Map<String, Map<String, dynamic>?> seed = const {},
  }) : _providers = List.of(initial),
       _settings = {...seed},
       super(db, Directory.systemTemp);

  final List<ProviderConfig> _providers;
  final Map<String, Map<String, dynamic>?> _settings;
  final Map<String, String> _keys = {};

  bool failFirstLoad = false;
  String? saveError;
  final List<ProviderConfig> saved = [];
  final List<String?> savedKeys = [];
  final List<String> deleted = [];
  final List<(String, Map<String, dynamic>)> savedSettings = [];

  Map<String, Map<String, dynamic>?> get settings => _settings;

  @override
  Future<List<ProviderConfig>> providers() async {
    if (failFirstLoad) {
      failFirstLoad = false;
      throw StateError('数据库暂时不可用');
    }
    return List.of(_providers);
  }

  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => _keys[id];

  @override
  Future<void> saveProvider(ProviderConfig provider, {String? key}) async {
    if (saveError != null) throw FormatException(saveError!);
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
    deleted.add(id);
    _providers.removeWhere((item) => item.id == id);
    _keys.remove(id);
  }

  @override
  Future<Map<String, dynamic>?> setting(String key) async => _settings[key];

  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    _settings[key] = value;
    savedSettings.add((key, value));
  }
}

ProviderConfig _provider({
  String id = 'p1',
  String name = '示例供应商',
  String baseUrl = 'https://api.example.com/v1',
  bool enabled = true,
}) {
  return ProviderConfig(id: id, name: name, baseUrl: baseUrl, enabled: enabled);
}

Future<void> _pumpPage(
  WidgetTester tester,
  StudioStore store, {
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: ProvidersPage(store: store),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(ValueKey(key));
  await _scrollTo(tester, finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await _scrollTo(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _selectDropdown(
  WidgetTester tester,
  String key,
  String option,
) async {
  await _tapKey(tester, key);
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  late Database database;

  setUpAll(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  });

  tearDownAll(() async => database.close());

  testWidgets('空列表显示空状态并打开发编辑页', (tester) async {
    final store = _FakeStore(database, []);
    await _pumpPage(tester, store);

    expect(find.text('还没有供应商'), findsOneWidget);
    expect(
      find.text('支持 OpenAI Images、Responses、WaveSpeed 和 EvoLink，填写地址和密钥后即可开始创作。'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('addProvider')));
    await tester.pumpAndSettle();

    expect(find.text('新增供应商'), findsOneWidget);
    final keyField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('providerApiKey')),
        matching: find.byType(TextField),
      ),
    );
    expect(keyField.controller?.text, isEmpty);
    expect(keyField.obscureText, isTrue);
  });

  for (final protocol in [ApiProtocol.wavespeed, ApiProtocol.evolink]) {
    testWidgets('新增 ${protocol.label} 协议保存默认地址和模型', (tester) async {
      final store = _FakeStore(database, []);
      await _pumpPage(tester, store);
      await tester.tap(find.byKey(const ValueKey('addProvider')));
      await tester.pumpAndSettle();
      await _enter(tester, 'providerName', protocol.label);
      await _selectDropdown(tester, 'providerProtocol', protocol.label);
      expect(find.byKey(const ValueKey('providerTransport')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
      await tester.pumpAndSettle();
      expect(store.saved.single.protocol, protocol);
      expect(store.saved.single.baseUrl, protocol == ApiProtocol.wavespeed ? 'https://api.wavespeed.ai/api/v3' : 'https://api.evolink.ai/v1');
      expect(store.saved.single.imageModel, protocol == ApiProtocol.wavespeed ? 'bytedance/seedream-v5.5/edit' : 'doubao-seedream-5.5');
    });
  }

  testWidgets('新增供应商保存全部字段并写入密钥', (tester) async {
    final store = _FakeStore(database, []);
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('addProvider')));
    await tester.pumpAndSettle();

    await _enter(tester, 'providerName', '我的中转');
    await _enter(
      tester,
      'providerBaseUrl',
      'https://gateway.example.com/openai/v1',
    );
    await _enter(tester, 'providerApiKey', '  sk-test  ');
    await _selectDropdown(tester, 'providerProtocol', 'Responses（图像工具）');
    await _selectDropdown(tester, 'providerTransport', 'JSON');
    await _tapKey(tester, 'providerAllowHttp');
    await _enter(tester, 'providerTimeout', '120');
    await _enter(tester, 'providerImageModel', 'image-x');
    await _enter(tester, 'providerResponseModel', 'response-x');
    await _enter(tester, 'providerToolModel', 'tool-x');
    await _enter(tester, 'providerPartialImages', '3');
    await _enter(tester, 'providerSafetyIdentifier', 'anon-test');
    await _tapKey(tester, 'providerFileInput');
    await _tapKey(tester, 'providerPromptCompatibility');

    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();

    expect(store.saved, hasLength(1));
    final config = store.saved.single;
    expect(config.name, '我的中转');
    expect(find.widgetWithText(TextField, '搜索模型'), findsOneWidget);
    expect(find.text('获取模型'), findsOneWidget);
    expect(config.baseUrl, 'https://gateway.example.com/openai/v1');
    expect(config.protocol, ApiProtocol.responses);
    expect(config.transport, TransportMode.json);
    expect(config.enabled, isTrue);
    expect(config.allowHttp, isTrue);
    expect(config.timeoutSeconds, 120);
    expect(config.imageModel, 'image-x');
    expect(config.responseModel, 'response-x');
    expect(config.toolModel, 'tool-x');
    expect(config.partialImages, 3);
    expect(config.safetyIdentifier, 'anon-test');
    expect(config.fileInput, isTrue);
    expect(config.promptCompatibility, isTrue);
    expect(store.savedKeys.single, 'sk-test');
    expect(find.text('我的中转'), findsOneWidget);
  });

  testWidgets('编辑时不回填密钥，留空保存不覆盖原密钥', (tester) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final store = _FakeStore(database, [_provider(name: '旧名字')]);
    store._keys['p1'] = 'sk-existing';
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('edit-p1')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('连接配置'));
    await tester.pumpAndSettle();
    expect(find.text('编辑供应商'), findsOneWidget);
    final nameField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('providerName')),
        matching: find.byType(TextField),
      ),
    );
    expect(nameField.controller?.text, '旧名字');
    final keyField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('providerApiKey')),
        matching: find.byType(TextField),
      ),
    );
    expect(keyField.controller?.text, isEmpty);
    expect(find.text('sk-existing'), findsNothing);
    expect(find.text('已保存的密钥不会显示；留空保持不变'), findsOneWidget);

    await tester.tap(find.byTooltip('复制已保存的密钥'));
    await tester.pumpAndSettle();
    expect(copied, 'sk-existing');
    expect(find.text('API 密钥已复制'), findsOneWidget);
    expect(keyField.controller?.text, isEmpty);

    await _enter(tester, 'providerName', '新名字');
    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();

    expect(store.saved.single.id, 'p1');
    expect(store.saved.single.name, '新名字');
    expect(store.savedKeys.single, isNull);
    expect(store._keys['p1'], 'sk-existing');
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('启用开关保存新状态', (tester) async {
    final store = _FakeStore(database, [_provider()]);
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('enabled-p1')));
    await tester.pumpAndSettle();

    expect(store.saved.single.enabled, isFalse);
    expect(find.text('已停用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('enabled-p1')));
    await tester.pumpAndSettle();
    expect(store.saved.last.enabled, isTrue);
  });

  testWidgets('设为默认写入 selection 设置', (tester) async {
    final store = _FakeStore(
      database,
      [_provider(), _provider(id: 'p2', name: '第二家')],
      seed: {
        'selection': {'providerId': 'p1'},
      },
    );
    await _pumpPage(tester, store);

    expect(find.text('默认'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('default-p2')));
    await tester.pumpAndSettle();

    expect(store.settings['selection'], {'providerId': 'p2'});
    expect(store.savedSettings.single.$1, 'selection');
    expect(find.text('已将「第二家」设为默认供应商'), findsOneWidget);
  });

  testWidgets('复制供应商不复制密钥', (tester) async {
    final store = _FakeStore(database, [_provider()]);
    store._keys['p1'] = 'sk-secret';
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('duplicate-p1')));
    await tester.pumpAndSettle();

    expect(store.saved, hasLength(1));
    final copy = store.saved.single;
    expect(copy.id, isNot('p1'));
    expect(copy.name, '示例供应商 副本');
    expect(store.savedKeys.single, isNull);
    expect(store._keys.containsKey(copy.id), isFalse);
    expect(store._keys['p1'], 'sk-secret');
    expect(find.text('示例供应商 副本'), findsOneWidget);
  });

  testWidgets('删除最后一个供应商需要确认，并清空默认选择', (tester) async {
    final store = _FakeStore(
      database,
      [_provider()],
      seed: {
        'selection': {'providerId': 'p1'},
      },
    );
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('delete-p1')));
    await tester.pumpAndSettle();
    expect(find.text('删除供应商？'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('confirmDeleteProvider')));
    await tester.pumpAndSettle();

    expect(store.deleted, ['p1']);
    expect(store.settings['selection'], {'providerId': null});
    expect(find.text('还没有供应商'), findsOneWidget);
  });

  testWidgets('删除可以取消', (tester) async {
    final store = _FakeStore(database, [_provider()]);
    await _pumpPage(tester, store);

    await tester.tap(find.byKey(const ValueKey('delete-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(store.deleted, isEmpty);
    expect(find.text('示例供应商'), findsOneWidget);
  });

  testWidgets('读取失败显示重试并可恢复', (tester) async {
    final store = _FakeStore(database, [_provider()])..failFirstLoad = true;
    await _pumpPage(tester, store);

    expect(find.text('无法读取供应商列表，请重试。'), findsOneWidget);
    expect(find.byKey(const ValueKey('providersRetry')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('providersRetry')));
    await tester.pumpAndSettle();

    expect(find.text('示例供应商'), findsOneWidget);
    expect(find.text('无法读取供应商列表，请重试。'), findsNothing);
  });

  testWidgets('字段校验拦截空值、HTTP 和范围', (tester) async {
    final store = _FakeStore(database, []);
    await _pumpPage(tester, store);
    await tester.tap(find.byKey(const ValueKey('addProvider')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('请输入供应商名称'), findsOneWidget);
    expect(find.text('请输入不含凭据、查询或片段的 API 地址'), findsOneWidget);
    expect(store.saved, isEmpty);

    await _enter(tester, 'providerName', '本地服务');
    await _enter(tester, 'providerBaseUrl', 'http://127.0.0.1:8080/v1');
    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('使用 HTTP 前请明确开启不安全连接'), findsOneWidget);

    await _tapKey(tester, 'providerAllowHttp');
    await _enter(tester, 'providerTimeout', '4000');
    expect(find.text('超时需为 1–3600 秒'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('超时需为 1–3600 秒'), findsOneWidget);

    await _enter(tester, 'providerTimeout', '30');
    await _enter(tester, 'providerPartialImages', '9');
    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();
    expect(find.text('预览帧数需为 0–3'), findsOneWidget);

    await _enter(tester, 'providerPartialImages', '2');
    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();

    expect(store.saved, hasLength(1));
    expect(store.saved.single.allowHttp, isTrue);
    expect(store.saved.single.timeoutSeconds, 30);
    expect(store.saved.single.partialImages, 2);
    expect(store.savedKeys.single, isNull);
  });

  testWidgets('保存异常显示错误并停留编辑页', (tester) async {
    final store = _FakeStore(database, [])..saveError = '密钥写入失败';
    await _pumpPage(tester, store);
    await tester.tap(find.byKey(const ValueKey('addProvider')));
    await tester.pumpAndSettle();
    await _enter(tester, 'providerName', '会失败的供应商');
    await _enter(tester, 'providerBaseUrl', 'https://api.example.com/v1');

    await tester.tap(find.byKey(const ValueKey('providerSaveButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('providerSaveError')), findsOneWidget);
    expect(find.text('密钥写入失败'), findsOneWidget);
    expect(find.text('新增供应商'), findsOneWidget);
    expect(store.saved, isEmpty);
  });

  testWidgets('大字体和键盘安全区下无溢出且保存按钮可点', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    final store = _FakeStore(database, [_provider()]);
    await _pumpPage(tester, store, textScaler: const TextScaler.linear(2));

    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('addProvider')));
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const ValueKey('providerSaveButton'));
    expect(saveButton, findsOneWidget);
    expect(tester.getSize(saveButton).height, greaterThanOrEqualTo(48));
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
    expect(find.text('请输入供应商名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
