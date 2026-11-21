import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/plugins/plugins_page.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore() : super(_UnusedDatabase(), Directory.systemTemp);
}

class _FakeManager extends PluginManager {
  _FakeManager(super.store);
  List<InstalledPlugin> plugins = [];
  final List<String> log = [];
  Object? error;
  Object? inspectError;
  int listFailures = 0;

  static const manifest = PluginManifest(
    id: 'com.example.upscale',
    name: '示例增强',
    version: '1.1.0',
    entry: 'main',
    providers: [
      PluginProviderSpec(
        id: 'p',
        name: '示例生图',
        planFunction: 'plan',
        interpretFunction: 'interpret',
        defaultBaseUrl: 'https://api.example.com',
      ),
    ],
    processors: [
      PluginProcessorSpec(id: 'pr', name: '放大', processFunction: 'process'),
    ],
    tools: [PluginToolSpec(id: 't', name: '批量放大', processorId: 'pr')],
    permissions: PluginPermissions(credentials: {'api.example.com'}),
  );

  @override
  Future<PluginManifest> inspect(Uint8List bytes) async {
    if (inspectError != null) throw inspectError!;
    return manifest;
  }

  @override
  Future<List<InstalledPlugin>> list() async {
    if (listFailures > 0) {
      listFailures--;
      throw StateError('数据库暂时不可用');
    }
    return List.of(plugins);
  }

  @override
  Future<InstalledPlugin> install(Uint8List bytes) async {
    if (error != null) throw error!;
    log.add('install:${bytes.length}');
    const installed = InstalledPlugin(
      id: 'com.example.upscale',
      name: '示例增强',
      version: '1.1.0',
      enabled: false,
      manifest: manifest,
    );
    plugins = [...plugins, installed];
    return installed;
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    log.add('enable:$id:$enabled');
    plugins = [
      for (final plugin in plugins)
        plugin.id == id ? plugin.copyWith(enabled: enabled) : plugin,
    ];
  }

  @override
  Future<void> uninstall(String id) async {
    log.add('uninstall:$id');
    plugins = [
      for (final plugin in plugins)
        if (plugin.id != id) plugin,
    ];
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeManager manager,
  Future<Uint8List?> Function()? pickArchive,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PluginsPage(
        store: manager.store,
        manager: manager,
        pickArchive: pickArchive,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final builtin = const InstalledPlugin(
    id: 'builtin.local-tools',
    name: '本地处理工具',
    version: '1.0.0',
    builtIn: true,
  );
  final sample = const InstalledPlugin(
    id: 'com.example.upscale',
    name: '示例增强',
    version: '1.0.0',
    enabled: false,
  );

  testWidgets('内置插件显示能力说明，内置项不可卸载', (tester) async {
    const providers = InstalledPlugin(
      id: 'builtin.providers',
      name: '内置生图适配器',
      version: '1.0.0',
      builtIn: true,
    );
    final manager = _FakeManager(_FakeStore())
      ..plugins = [builtin, providers, sample];
    await _pump(tester, manager: manager);
    expect(find.text('本地处理工具'), findsOneWidget);
    expect(
      find.text(
        '随应用提供 OpenAI Images、OpenAI Responses、WaveSpeed 和 EvoLink 四种生图协议适配器；供应商账号与模型在供应商页面分别配置。',
      ),
      findsOneWidget,
    );
    expect(
      find.text('提供缩放和水印工具，可手动处理图片或加入创作前后处理；图片仅在本机处理，原图不会被覆盖。'),
      findsOneWidget,
    );
    expect(find.text('内置'), findsNWidgets(2));
    expect(find.text('v1.0.0'), findsNWidgets(3));
    expect(find.byTooltip('卸载插件'), findsOneWidget);
  });

  testWidgets('启停开关调用 setEnabled 并刷新', (tester) async {
    final manager = _FakeManager(_FakeStore())..plugins = [sample];
    await _pump(tester, manager: manager);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(manager.log, ['enable:com.example.upscale:true']);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('安装前展示真实清单，安装后保持未启用', (tester) async {
    final manager = _FakeManager(_FakeStore());
    await _pump(
      tester,
      manager: manager,
      pickArchive: () async => Uint8List.fromList([1, 2, 3]),
    );
    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    expect(find.text('安装 示例增强 1.1.0？'), findsOneWidget);
    expect(find.text('· 生图服务 1 个（示例生图）'), findsOneWidget);
    expect(find.text('· 图片处理器 1 个（放大）'), findsOneWidget);
    expect(find.text('· 工具 1 个（批量放大）'), findsOneWidget);
    expect(find.text('· 仅向 api.example.com 发起请求'), findsOneWidget);
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();
    expect(manager.log, ['install:3']);
    expect(find.text('示例增强 1.1.0 已安装，尚未启用'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('无效 ZIP 在展示清单前被拒绝', (tester) async {
    final manager = _FakeManager(_FakeStore())
      ..inspectError = const PluginException('插件缺少 manifest.json');
    await _pump(
      tester,
      manager: manager,
      pickArchive: () async => Uint8List.fromList([1]),
    );
    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    expect(find.text('插件缺少 manifest.json'), findsOneWidget);
    expect(manager.log, isEmpty);
  });

  testWidgets('启用插件前展示声明的权限', (tester) async {
    final manager = _FakeManager(_FakeStore())
      ..plugins = [
        const InstalledPlugin(
          id: 'com.example.upscale',
          name: '示例增强',
          version: '1.1.0',
          enabled: false,
          manifest: _FakeManager.manifest,
        ),
      ];
    await _pump(tester, manager: manager);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('启用 示例增强？'), findsOneWidget);
    expect(find.text('· 仅向 api.example.com 发起请求'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.log, isEmpty);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();
    expect(manager.log, ['enable:com.example.upscale:true']);
  });

  testWidgets('取消确认不会安装', (tester) async {
    final manager = _FakeManager(_FakeStore());
    await _pump(
      tester,
      manager: manager,
      pickArchive: () async => Uint8List.fromList([1]),
    );
    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.log, isEmpty);
  });

  testWidgets('超大 ZIP 被拦下，不进入确认', (tester) async {
    final manager = _FakeManager(_FakeStore());
    await _pump(
      tester,
      manager: manager,
      pickArchive: () async => Uint8List(maxPluginArchiveBytes + 1),
    );
    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    expect(find.text('安装或更新插件？'), findsNothing);
    expect(find.text('插件 ZIP 不能超过 16 MB'), findsOneWidget);
    expect(manager.log, isEmpty);
  });

  testWidgets('安装失败显示插件错误信息', (tester) async {
    final manager = _FakeManager(_FakeStore())
      ..error = const PluginException('插件 ID 与已安装版本冲突');
    await _pump(
      tester,
      manager: manager,
      pickArchive: () async => Uint8List.fromList([1]),
    );
    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();
    expect(find.text('插件 ID 与已安装版本冲突'), findsOneWidget);
  });

  testWidgets('卸载需要确认并移除条目', (tester) async {
    final manager = _FakeManager(_FakeStore())..plugins = [sample];
    await _pump(tester, manager: manager);
    await tester.tap(find.byTooltip('卸载插件'));
    await tester.pumpAndSettle();
    expect(find.text('卸载 示例增强？'), findsOneWidget);
    await tester.tap(find.text('卸载'));
    await tester.pumpAndSettle();
    expect(manager.log, ['uninstall:com.example.upscale']);
    expect(find.text('还没有安装插件，导入 ZIP 即可添加能力'), findsOneWidget);
  });

  testWidgets('读取失败可重试', (tester) async {
    final manager = _FakeManager(_FakeStore())
      ..plugins = [sample]
      ..listFailures = 1;
    await _pump(tester, manager: manager);
    expect(find.text('读取插件列表失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('示例增强'), findsOneWidget);
  });
}
