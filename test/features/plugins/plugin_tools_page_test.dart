import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/plugins/plugin_tools_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:image_gen/plugins/local_processing.dart';
import 'package:image_gen/plugins/plugin_contract.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore({this.taskList = const []}) : super(_UnusedDatabase(), Directory.systemTemp);

  final List<StudioTask> taskList;
  final List<ProcessingStep> derived = [];
  final List<ImageAsset> saved = [];

  @override
  Future<List<StudioTask>> tasks() async => List.of(taskList);

  @override
  Future<ImageAsset> saveAsset(Uint8List bytes, String mime, {String? remoteUrl}) async {
    final asset = _asset('s${saved.length}', mime: mime);
    saved.add(asset);
    return asset;
  }

  @override
  Future<String> recordDerivedImage({required ImageAsset source, required ImageAsset result, required ProcessingStep step}) async {
    derived.add(step);
    return 'relation';
  }
}

String _hash(String id) => id.padRight(64, '0');

ImageAsset _asset(String id, {String mime = 'image/png', int? width = 800, int? height = 600}) =>
    ImageAsset(id: id, path: 'assets/${_hash(id)}.png', mime: mime, hash: _hash(id), bytes: 2048, width: width, height: height);

ImageAsset _output(String id) => _asset(id);

PluginToolkit _toolkit({
  List<ToolDescriptor>? tools,
  Future<ImageAsset> Function(ImageAsset, ProcessingStep, {bool Function()? isCancelled})? process,
}) => PluginToolkit(
  tools: tools ?? builtinTools(),
  process: process ?? (image, step, {isCancelled}) async => _output('out-${image.id}'),
);

Future<void> _scrollDown(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, -600));
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, _FakeStore store, {required PluginToolkit toolkit, List<ImageAsset> images = const []}) async {
  await tester.pumpWidget(MaterialApp(home: PluginToolsPage(store: store, initialImages: images, loader: (_) async => toolkit)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('没有图片时提示先添加', (tester) async {
    final store = _FakeStore();
    await _pump(tester, store, toolkit: _toolkit());
    expect(find.text('批量水印'), findsOneWidget);
    expect(find.text('调整尺寸'), findsOneWidget);
    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    expect(find.text('请先添加要处理的图片'), findsOneWidget);
  });

  testWidgets('多图处理登记派生结果', (tester) async {
    final store = _FakeStore();
    final calls = <String>[];
    await _pump(
      tester,
      store,
      toolkit: _toolkit(
        process: (image, step, {isCancelled}) async {
          calls.add(step.processorId);
          return _output('out-${image.id}');
        },
      ),
      images: [_asset('a'), _asset('b')],
    );
    expect(find.text('处理 2 张图片'), findsNWidgets(2));
    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    expect(find.text('水印文字'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '处理 2 张图片'));
    await tester.pumpAndSettle();
    expect(calls, ['local.watermark', 'local.watermark']);
    expect(store.derived.length, 2);
    expect(store.derived.first.pluginId, builtinLocalPluginId);
    expect(store.derived.first.version, builtinLocalVersion);
    await _scrollDown(tester);
    expect(find.text('已保存到作品'), findsNWidgets(2));
  });

  testWidgets('参数越界时不执行', (tester) async {
    final store = _FakeStore();
    var calls = 0;
    await _pump(
      tester,
      store,
      toolkit: _toolkit(
        process: (image, step, {isCancelled}) async {
          calls++;
          return _output('out');
        },
      ),
      images: [_asset('a')],
    );
    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '5');
    await tester.pump();
    await tester.tap(find.text('开始处理'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('不透明度 不能大于 1'), findsOneWidget);
  });

  testWidgets('取消后不再处理剩余图片且不登记', (tester) async {
    final store = _FakeStore();
    var calls = 0;
    await _pump(
      tester,
      store,
      toolkit: _toolkit(
        process: (image, step, {isCancelled}) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          if (isCancelled?.call() ?? false) throw const ProcessingCancelled();
          return _output('out-${image.id}');
        },
      ),
      images: [_asset('a'), _asset('b')],
    );
    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '处理 2 张图片'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('取消'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(store.derived, isEmpty);
    expect(find.textContaining('已取消'), findsOneWidget);
  });

  testWidgets('单图失败不阻断其余图片', (tester) async {
    final store = _FakeStore();
    await _pump(
      tester,
      store,
      toolkit: _toolkit(
        process: (image, step, {isCancelled}) async {
          if (image.id == 'a') throw const FormatException('图片内容无法解码');
          return _output('out-${image.id}');
        },
      ),
      images: [_asset('a'), _asset('b')],
    );
    await tester.tap(find.text('批量水印'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '处理 2 张图片'));
    await tester.pumpAndSettle();
    expect(store.derived.length, 1);
    expect(find.text('完成 1 张，失败 1 张'), findsOneWidget);
    await _scrollDown(tester);
    expect(find.text('图片内容无法解码'), findsOneWidget);
  });

  testWidgets('可从作品选择图片', (tester) async {
    final store = _FakeStore(
      taskList: [
        StudioTask(
          input: GenerationInput(taskId: 't1', provider: const ProviderConfig(id: 'p', name: '供应商', baseUrl: 'https://api.example.com'), prompt: '猫', params: const GenerationParams()),
          status: TaskStatus.done,
          createdAt: DateTime(2024),
          outputs: [_asset('x'), _asset('y')],
        ),
      ],
    );
    await _pump(tester, store, toolkit: _toolkit());
    await tester.tap(find.text('从作品选择'));
    await tester.pumpAndSettle();
    expect(find.text('从作品选择（已选 0 张）'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加所选图片'));
    await tester.pumpAndSettle();
    expect(find.text('待处理图片（1 张）'), findsOneWidget);
  });

  testWidgets('工具集读取失败可重试', (tester) async {
    final store = _FakeStore();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PluginToolsPage(
          store: store,
          loader: (_) async {
            if (attempts++ == 0) throw StateError('插件损坏');
            return _toolkit();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('读取本地工具失败，请重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('批量水印'), findsOneWidget);
  });
}