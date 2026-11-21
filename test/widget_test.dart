import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/main.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NavigationStore extends StudioStore {
  _NavigationStore({this.theme}) : super(_UnusedDatabase(), Directory.systemTemp);
  final String? theme;
  @override
  Future<Map<String, dynamic>?> setting(String key) async => key == 'appearance' ? {'theme': theme} : null;
  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {}
  @override
  Future<List<ProviderConfig>> providers() async => [];
  @override
  Future<List<StudioTask>> tasks() async => [];
  @override
  Future<List<Map<String, Object?>>> categories() async => [];
}

void main() {
  testWidgets('应用入口不抢占返回键，展开的生图面板先收起', (tester) async {
    final store = _NavigationStore();
    await tester.pumpWidget(ImageStudioApp(store: store));
    await tester.pumpAndSettle();
    expect(find.byType(WithForegroundTask), findsNothing);
    final panel = tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer')));
    expect(panel.controller!.size, greaterThan(panel.minChildSize + .01));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(panel.controller!.size, closeTo(panel.minChildSize, .01));
    expect(find.byKey(const ValueKey('open-composer')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    store.dispose();
  });
  testWidgets('启动时立即应用已保存的深色主题', (tester) async {
    final store = _NavigationStore(theme: 'dark');
    await tester.pumpWidget(ImageStudioApp(store: store));
    await tester.pumpAndSettle();
    final context = tester.element(find.byKey(const ValueKey('open-composer')));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).scaffoldBackgroundColor, const Color(0xff030712));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });
  testWidgets('主页展示历史和提示词入口，设置页保留供应商管理', (tester) async {
    final store = _NavigationStore();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      store.dispose();
    });
    await tester.pumpWidget(ImageStudioApp(store: store));
    await tester.pumpAndSettle();
    expect(find.text('生图'), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, '生图');
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('open-composer')), findsOneWidget);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('供应商与模型'), findsOneWidget);
    await tester.ensureVisible(find.text('关于生图'));
    await tester.tap(find.text('关于生图'));
    await tester.pumpAndSettle();
    expect(tester.widget<AboutDialog>(find.byType(AboutDialog)).applicationName, '生图');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('供应商与模型'));
    await tester.pumpAndSettle();
    expect(find.text('新增供应商'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
