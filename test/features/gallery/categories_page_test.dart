import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/gallery/categories_page.dart';
import 'package:sqflite/sqflite.dart';

class _Database implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class _Store extends StudioStore {
  _Store() : super(_Database(), Directory.systemTemp);
  final items = <Map<String, Object?>>[];
  @override
  Future<List<Map<String, Object?>>> categories() async => List.of(items);
  @override
  Future<void> saveCategory(String id, String name) async {
    items.removeWhere((item) => item['id'] == id);
    items.add({'id': id, 'name': name});
    notifyListeners();
  }
  @override
  Future<void> deleteCategory(String id) async {
    items.removeWhere((item) => item['id'] == id);
    notifyListeners();
  }
}
void main() {
  testWidgets('分类页可以新建、重命名与删除分类', (tester) async {
    final store = _Store();
    await tester.pumpWidget(MaterialApp(home: CategoriesPage(store: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建分类'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '风景');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('风景'), findsOneWidget);
    final id = store.items.single['id'];
    await tester.tap(find.text('风景'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '人物');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('人物'), findsOneWidget);
    expect(store.items.single['id'], id);
    await tester.tap(find.byTooltip('删除分类（保留作品）'));
    await tester.pumpAndSettle();
    expect(store.items, isEmpty);
    expect(find.text('人物'), findsNothing);
  });
}
