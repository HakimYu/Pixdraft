import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/plugins/plugin_tools_page.dart';
import 'package:image_gen/features/plugins/plugins_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/local_processing.dart';
import 'package:image_gen/plugins/plugin_manifest.dart';
import 'package:image_gen/plugins/plugin_manager.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore() : super(_UnusedDatabase(), Directory.systemTemp);

  final List<ProcessingStep> derived = [];

  @override
  Future<List<StudioTask>> tasks() async => const [];

  @override
  Future<ImageAsset> saveAsset(
    Uint8List bytes,
    String mime, {
    String? remoteUrl,
  }) async => _asset('result');

  @override
  Future<String> recordDerivedImage({
    required ImageAsset source,
    required ImageAsset result,
    required ProcessingStep step,
  }) async {
    derived.add(step);
    return 'relation';
  }
}

class _FakeManager extends PluginManager {
  _FakeManager(super.store);

  @override
  Future<List<InstalledPlugin>> list() async => const [
    InstalledPlugin(
      id: 'builtin.local-tools',
      name: '内置本地处理',
      version: '1.0.0',
      builtIn: true,
    ),
    InstalledPlugin(
      id: 'com.example.very-long-plugin-id-for-narrow-screen',
      name: '一个名字特别长的第三方图片增强插件示例',
      version: '12.34.56',
      enabled: false,
      manifest: PluginManifest(
        id: 'com.example.very-long-plugin-id-for-narrow-screen',
        name: '一个名字特别长的第三方图片增强插件示例',
        version: '12.34.56',
        entry: 'index.js',
        providers: [
          PluginProviderSpec(
            id: 'p',
            name: '示例生图服务名称也很长',
            planFunction: 'plan',
            interpretFunction: 'interpret',
            defaultBaseUrl: 'https://api.example.com',
          ),
        ],
        processors: [
          PluginProcessorSpec(
            id: 'pr',
            name: '超分辨率增强处理器',
            processFunction: 'process',
          ),
        ],
        tools: [
          PluginToolSpec(
            id: 't',
            name: '批量超分辨率增强工具',
            processorId: 'pr',
          ),
        ],
        permissions: PluginPermissions(
          credentials: {'api.example.com', 'cdn.example.org'},
        ),
      ),
    ),
  ];

  @override
  Future<PluginManifest> inspect(Uint8List bytes) async =>
      (await list()).last.manifest!;
}

ImageAsset _asset(String id, {int? width = 1024, int? height = 768}) =>
    ImageAsset(
      id: id,
      path: 'assets/${id.padRight(64, '0')}.png',
      mime: 'image/png',
      hash: id.padRight(64, '0'),
      bytes: 4096,
      width: width,
      height: height,
    );

PluginToolkit _toolkit() => PluginToolkit(
  tools: builtinTools(),
  process: (image, step, {isCancelled}) async => _asset('out-${image.id}'),
);

Widget _app(Widget home) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(1.4)),
    child: child!,
  ),
  home: home,
);

Future<void> _narrow(WidgetTester tester, Widget home) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(home));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('窄屏放大字体时插件列表与清单确认不溢出', (tester) async {
    final store = _FakeStore();
    await _narrow(
      tester,
      PluginsPage(
        store: store,
        manager: _FakeManager(store),
        pickArchive: () async => Uint8List.fromList([1, 2, 3]),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('内置'), findsOneWidget);

    await tester.tap(find.text('导入插件 ZIP'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('把 一个名字特别长的第三方图片增强插件示例 更新到 12.34.56？'), findsOneWidget);
    expect(find.text('· 仅向 api.example.com、cdn.example.org 发起请求'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏放大字体时工具列表与运行页不溢出', (tester) async {
    final store = _FakeStore();
    await _narrow(
      tester,
      PluginToolsPage(
        store: store,
        initialImages: [_asset('a'), _asset('b')],
        loader: (_) async => _toolkit(),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('待处理图片（2 张）'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    final run = find.widgetWithText(FilledButton, '处理 2 张图片');
    expect(run, findsOneWidget);
    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.derived.length, 2);
  });
}