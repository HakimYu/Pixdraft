import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/providers/provider_connection.dart';
import 'package:image_gen/features/providers/provider_detail_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite/sqflite.dart';

class _Database implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store extends StudioStore {
  _Store(this.provider) : super(_Database(), Directory.systemTemp);
  ProviderConfig provider;
  bool fail = false;
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => 'test-key';
  @override
  Future<void> saveProvider(ProviderConfig value, {String? key}) async {
    if (fail) throw StateError('disk');
    provider = ProviderConfig.fromJson(value.toJson());
  }
}

class _Checker extends ProviderModelChecker {
  ModelCheckResult result = const ModelCheckResult(ModelCheckStatus.ok, '获取成功', models: ['remote-image', 'another-image']);
  int calls = 0;
  @override
  Future<ModelCheckResult> check(ProviderConfig provider, String? apiKey) async {
    calls++;
    return result;
  }
}

Future<void> _pump(WidgetTester tester, _Store store, _Checker checker) async {
  await tester.pumpWidget(MaterialApp(home: ProviderDetailPage(store: store, provider: store.provider, checker: checker)));
  await tester.tap(find.text('模型'));
  await tester.pumpAndSettle();
}

void main() {
  const provider = ProviderConfig(id: 'p', name: '示例', baseUrl: 'https://example.test/v1');

  test('旧配置迁移默认模型，新配置保留空列表与去重', () {
    final old = provider.toJson()..remove('models');
    expect(ProviderConfig.fromJson(old).enabledModels, ['gpt-image-1']);
    expect(ProviderConfig.fromJson({...old, 'protocol': 'responses'}).enabledModels, ['gpt-image-1', 'gpt-4.1']);
    expect(ProviderConfig.fromJson({...old, 'models': <String>[]}).enabledModels, isEmpty);
    expect(ProviderConfig.fromJson({...old, 'models': [' a ', 'a', '']}).enabledModels, ['a']);
  });

  testWidgets('获取只更新候选，启用移除保存，刷新失败保留候选', (tester) async {
    final store = _Store(provider);
    final checker = _Checker();
    await _pump(tester, store, checker);
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();
    expect(store.provider.enabledModels, ['gpt-image-1']);
    await tester.tap(find.byTooltip('启用 remote-image'));
    await tester.pumpAndSettle();
    expect(store.provider.enabledModels, ['gpt-image-1', 'remote-image']);
    expect(checker.calls, 1);
    await tester.tap(find.byTooltip('移除 gpt-image-1'));
    await tester.pumpAndSettle();
    expect(store.provider.imageModel, 'remote-image');
    expect(store.provider.enabledModels, ['remote-image']);
    checker.result = const ModelCheckResult(ModelCheckStatus.failed, '获取失败');
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('启用 another-image'), findsOneWidget);
    expect(find.text('获取失败'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '搜索模型'), 'remote');
    await tester.pumpAndSettle();
    expect(find.byTooltip('启用 another-image'), findsNothing);
    expect(find.byTooltip('移除 remote-image'), findsOneWidget);
  });

  testWidgets('手动添加去重，保存失败不更新列表，移除最后模型保留空列表', (tester) async {
    final store = _Store(provider);
    final checker = _Checker();
    await _pump(tester, store, checker);
    await tester.tap(find.text('手动添加'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '模型 ID'), ' custom-model ');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(store.provider.enabledModels, ['gpt-image-1', 'custom-model']);
    store.fail = true;
    await tester.tap(find.byTooltip('移除 custom-model'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('移除 custom-model'), findsOneWidget);
    expect(find.text('保存失败，请重试'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.byTooltip('移除 custom-model'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除 gpt-image-1'));
    await tester.pumpAndSettle();
    expect(store.provider.enabledModels, isEmpty);
    expect(ProviderConfig.fromJson(store.provider.toJson()).enabledModels, isEmpty);
  });

  testWidgets('模型排序只在进入时置顶启用项，切换和搜索保持原有位置', (tester) async {
    final store = _Store(provider);
    final checker = _Checker();
    await _pump(tester, store, checker);
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();
    double y(String id) => tester.getTopLeft(find.byTooltip(id)).dy;
    final before = y('启用 remote-image');
    await tester.tap(find.byTooltip('启用 remote-image'));
    await tester.pumpAndSettle();
    expect(y('移除 remote-image'), before);
    await tester.tap(find.byTooltip('移除 gpt-image-1'));
    await tester.pumpAndSettle();
    expect(y('启用 gpt-image-1'), lessThan(y('启用 another-image')));
    await tester.enterText(find.widgetWithText(TextField, '搜索模型'), ' REMOTE ');
    await tester.pumpAndSettle();
    expect(find.byTooltip('移除 remote-image'), findsOneWidget);
    expect(find.byTooltip('启用 another-image'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '搜索模型'), '');
    await tester.pumpAndSettle();
    expect(y('移除 remote-image'), before);
  });

  testWidgets('Responses 两个默认模型分别保存', (tester) async {
    final store = _Store(ProviderConfig.fromJson({...provider.toJson(), 'protocol': 'responses', 'models': ['main-a', 'tool-b'], 'responseModel': 'main-a', 'toolModel': 'tool-b'}));
    await _pump(tester, store, _Checker());
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Responses 主模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tool-b').last);
    await tester.pumpAndSettle();
    expect(store.provider.responseModel, 'tool-b');
    expect(store.provider.toolModel, 'tool-b');
    expect(provider.imageModel, 'gpt-image-1');
  });
}
