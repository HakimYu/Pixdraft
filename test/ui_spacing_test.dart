import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/gallery/error_details.dart';
import 'package:image_gen/features/gallery/error_log_page.dart';
import 'package:image_gen/features/providers/provider_detail_page.dart';
import 'package:image_gen/features/providers/provider_editor_page.dart';
import 'package:image_gen/main.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite/sqflite.dart';

class _Database implements Database {
  @override
  Future<List<Map<String, Object?>>> query(String table, {bool? distinct, List<String>? columns, String? where, List<Object?>? whereArgs, String? groupBy, String? having, String? orderBy, int? limit, int? offset}) async => [
    for (var i = 0; i < 2; i++) {'message': '供应商返回错误，模型不支持当前请求，请检查模型与请求参数后重试\nHTTP 400', 'task_id': 'task-$i', 'created_at': '2026-11-12 12:47:49'},
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store extends StudioStore {
  _Store() : super(_Database(), Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> setting(String key) async => null;
  @override
  Future<List<ProviderConfig>> providers() async => [];
  @override
  Future<List<StudioTask>> tasks() async => [];
  @override
  Future<List<Map<String, Object?>>> categories() async => [];
  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => null;
}

Future<void> _open(WidgetTester tester, _Store store, Widget page, {double width = 390, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    store.dispose();
  });
  await tester.pumpWidget(ImageStudioApp(store: store));
  await tester.pumpAndSettle();
  final context = tester.element(find.byKey(const ValueKey('open-composer')));
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: page)));
  await tester.pumpAndSettle();
}

void main() {
  for (final protocol in ApiProtocol.values) {
    testWidgets('$protocol 模型页说明、默认模型与搜索框留出间距', (tester) async {
      final store = _Store();
      final provider = ProviderConfig(id: 'p', name: '供应商', baseUrl: 'https://example.test/v1', protocol: protocol);
      await _open(tester, store, ProviderDetailPage(store: store, provider: provider));
      await tester.tap(find.text('模型'));
      await tester.pumpAndSettle();
      final fields = find.byType(DropdownButtonFormField<String>);
      final help = tester.getRect(find.text('加号启用，减号移除。模型列表不能判断图像能力，请按供应商说明选择。'));
      final buttons = tester.getRect(find.widgetWithText(OutlinedButton, '获取模型'));
      expect(help.top - buttons.bottom, greaterThanOrEqualTo(12));
      expect(tester.getRect(fields.first).top - help.bottom, greaterThanOrEqualTo(20));
      if (protocol == ApiProtocol.responses) {
        expect(tester.getRect(fields.last).top - tester.getRect(fields.first).bottom, greaterThanOrEqualTo(16));
      }
      final search = tester.getRect(find.widgetWithText(TextField, '搜索模型'));
      expect(search.top - tester.getRect(fields.last).bottom, greaterThanOrEqualTo(16));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('窄屏放大字体时模型页和连接表单不溢出', (tester) async {
    final store = _Store();
    const provider = ProviderConfig(id: 'p', name: '供应商', baseUrl: 'https://example.test/v1', protocol: ApiProtocol.responses);
    await _open(tester, store, ProviderDetailPage(store: store, provider: provider), width: 320, scale: 1.4);
    await tester.tap(find.text('模型'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final context = tester.element(find.byType(ProviderDetailPage));
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: ProviderEditorPage(store: store, provider: provider))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('providerResponseModel')), 200, scrollable: find.descendant(of: find.byType(ProviderEditorPage), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('providerResponseModel'))).top - tester.getRect(find.byKey(const ValueKey('providerImageModel'))).bottom, greaterThanOrEqualTo(20));
    final list = find.byType(ListView).last;
    for (var i = 0; i < 6; i++) {
      await tester.drag(list, const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏错误记录的操作、元信息和下一条记录不重叠', (tester) async {
    final store = _Store();
    await _open(tester, store, ErrorLogPage(store: store), width: 320, scale: 1.4);
    final reports = find.byType(ErrorDetails);
    final metadata = find.text('2026-11-12 12:47:49\n任务 task-0');
    expect(tester.getRect(metadata).top - tester.getRect(reports.first).bottom, greaterThanOrEqualTo(8));
    expect(tester.getRect(reports.at(1)).top - tester.getRect(metadata).bottom, greaterThanOrEqualTo(32));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
