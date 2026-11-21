import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/create/prompt_library_page.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore({List<Map<String, Object?>> prompts = const []})
    : _prompts = List.of(prompts),
      super(_UnusedDatabase(), Directory.systemTemp);

  final List<Map<String, Object?>> _prompts;
  final List<(String, String, String)> saved = [];
  final List<String> deleted = [];
  bool failLoadOnce = false;
  bool failSave = false;

  @override
  Future<List<Map<String, Object?>>> prompts() async {
    if (failLoadOnce) {
      failLoadOnce = false;
      throw StateError('数据库暂时不可用');
    }
    return List.of(_prompts);
  }

  @override
  Future<void> savePrompt(String id, String title, String content) async {
    if (failSave) throw const FormatException('提示词不能为空');
    saved.add((id, title, content));
    _prompts.removeWhere((p) => p['id'] == id);
    _prompts.insert(0, {'id': id, 'title': title, 'content': content});
  }

  @override
  Future<void> deletePrompt(String id) async {
    deleted.add(id);
    _prompts.removeWhere((p) => p['id'] == id);
  }
}

List<Map<String, Object?>> _seed() => [
  {'id': 'p1', 'title': '雪山', 'content': '白雪覆盖的山峰'},
  {'id': 'p2', 'title': '海边', 'content': '黄昏的海浪与云海'},
];

Future<void> _pump(
  WidgetTester tester,
  _FakeStore store, {
  String current = '',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PromptLibraryPage(store: store, current: current),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('按标题和内容搜索，无结果有提示', (tester) async {
    final store = _FakeStore(prompts: _seed());
    await _pump(tester, store);

    expect(find.widgetWithText(ListTile, '雪山'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '海边'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '雪山');
    await tester.pump();
    expect(find.widgetWithText(ListTile, '雪山'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '海边'), findsNothing);

    await tester.enterText(find.byType(TextField), '云海');
    await tester.pump();
    expect(find.widgetWithText(ListTile, '海边'), findsOneWidget);
    expect(find.widgetWithText(ListTile, '雪山'), findsNothing);

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump();
    expect(find.text('没有匹配的提示词'), findsOneWidget);
  });

  testWidgets('编辑已有提示词并保存后刷新列表', (tester) async {
    final store = _FakeStore(prompts: _seed());
    await _pump(tester, store);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.text('编辑提示词'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      '雪山',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      '白雪覆盖的山峰',
    );

    await tester.enterText(find.byType(TextField).at(0), '雪山清晨');
    await tester.enterText(find.byType(TextField).at(1), '清晨的雪山与薄雾');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(store.saved.single.$1, 'p1');
    expect(store.saved.single.$2, '雪山清晨');
    expect(store.saved.single.$3, '清晨的雪山与薄雾');
    expect(find.text('雪山清晨'), findsOneWidget);
    expect(find.text('编辑提示词'), findsNothing);
  });

  testWidgets('保存当前提示词且标题留空时用首行', (tester) async {
    final store = _FakeStore();
    await _pump(tester, store, current: '一只猫\n坐在窗台上');

    await tester.tap(find.text('保存当前提示词'));
    await tester.pumpAndSettle();
    expect(find.text('新增提示词'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      '一只猫\n坐在窗台上',
    );

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(store.saved.single.$2, '一只猫');
    expect(store.saved.single.$3, '一只猫\n坐在窗台上');
    expect(find.text('一只猫'), findsOneWidget);
  });

  testWidgets('删除提示词需要确认', (tester) async {
    final store = _FakeStore(prompts: _seed());
    await _pump(tester, store);

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除提示词？'), findsOneWidget);
    expect(store.deleted, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(store.deleted, ['p1']);
    expect(find.widgetWithText(ListTile, '雪山'), findsNothing);
    expect(find.widgetWithText(ListTile, '海边'), findsOneWidget);
  });

  testWidgets('读取失败显示重试并可恢复', (tester) async {
    final store = _FakeStore(prompts: _seed())..failLoadOnce = true;
    await _pump(tester, store);

    expect(find.text('无法读取提示词，请重试'), findsOneWidget);
    expect(find.text('没有匹配的提示词'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('无法读取提示词，请重试'), findsNothing);
    expect(find.widgetWithText(ListTile, '雪山'), findsOneWidget);
  });

  testWidgets('保存内容为空时提示错误并停留在编辑页', (tester) async {
    final store = _FakeStore()..failSave = true;
    await _pump(tester, store);

    await tester.tap(find.byTooltip('新增提示词'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('保存失败，请填写内容并检查存储空间'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(store.saved, isEmpty);
  });
}
