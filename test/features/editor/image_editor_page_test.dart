import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/editor/editor_export.dart';
import 'package:image_gen/features/editor/editor_geometry.dart';
import 'package:image_gen/features/editor/image_editor_page.dart';
import 'package:image_gen/features/studio_image.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _pngHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _gifHash = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _svgHash = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

final _source = ImageAsset(
  id: 'src',
  path: 'assets/$_pngHash.png',
  mime: 'image/png',
  hash: _pngHash,
  bytes: 1,
);

ImageAsset _asset(String id, String hash, String ext, String mime) =>
    ImageAsset(id: id, path: 'assets/$hash.$ext', mime: mime, hash: hash, bytes: 1);

class _FakeStore extends StudioStore {
  _FakeStore(super.db, super.root);

  final Map<String, Map<String, dynamic>> settings = {};
  final List<Uint8List> saved = [];
  final List<String> savedMimes = [];
  bool failSave = false;
  Completer<void>? saveGate;

  @override
  Future<Map<String, dynamic>?> setting(String key) async => settings[key];

  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    settings[key] = value;
  }

  @override
  Future<ImageAsset> saveAsset(
    Uint8List bytes,
    String mime, {
    String? remoteUrl,
  }) async {
    final gate = saveGate;
    if (gate != null) await gate.future;
    if (failSave) throw StateError('磁盘已满');
    saved.add(bytes);
    savedMimes.add(mime);
    return ImageAsset(
      id: 'saved',
      path: 'assets/$_otherHash.png',
      mime: mime,
      hash: _otherHash,
      bytes: bytes.length,
    );
  }
}

class _Harness extends StatelessWidget {
  const _Harness({
    required this.store,
    required this.source,
    this.initialMask,
    this.initialMarkup,
    this.onResult,
  });

  final StudioStore store;
  final ImageAsset source;
  final ImageAsset? initialMask, initialMarkup;
  final ValueChanged<ImageEditResult?>? onResult;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('launchEditor'),
              onPressed: () async {
                final result = await Navigator.of(context).push<ImageEditResult>(
                  MaterialPageRoute(
                    builder: (_) => ImageEditorPage(
                      store: store,
                      source: source,
                      initialMask: initialMask,
                      initialMarkup: initialMarkup,
                    ),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _open(
  WidgetTester tester, {
  required _FakeStore store,
  ImageAsset? source,
  ImageAsset? initialMask,
  ImageAsset? initialMarkup,
  ValueChanged<ImageEditResult?>? onResult,
}) async {
  await tester.pumpWidget(
    _Harness(
      store: store,
      source: source ?? _source,
      initialMask: initialMask,
      initialMarkup: initialMarkup,
      onResult: onResult,
    ),
  );
  await tester.tap(find.byKey(const ValueKey('launchEditor')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  for (var i = 0; i < 10; i++) {
    if (find.byKey(const ValueKey('editorCanvas')).evaluate().isNotEmpty ||
        find.byKey(const ValueKey('editorError')).evaluate().isNotEmpty) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _saveAndWait(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const ValueKey('editorSave')));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

String _statusOf(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('editorStatus'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late Directory root;
  late Uint8List sourcePng;

  setUpAll(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    root = await Directory.systemTemp.createTemp('image_editor_test_');
    sourcePng = await encodeMask(
      40,
      30,
      const Rect.fromLTRB(.4, .4, .6, .6),
    );
    final assets = Directory('${root.path}/assets');
    await assets.create();
    await File('${assets.path}/$_pngHash.png').writeAsBytes(sourcePng);
  });

  tearDownAll(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  testWidgets('GIF 明确提示不可编辑，且不提供保存入口', (tester) async {
    final store = _FakeStore(db, root);
    await _open(
      tester,
      store: store,
      source: _asset('gif', _gifHash, 'gif', 'image/gif'),
    );

    expect(find.byKey(const ValueKey('editorError')), findsOneWidget);
    expect(find.textContaining('GIF'), findsOneWidget);
    expect(find.byKey(const ValueKey('editorSave')), findsNothing);
  });

  testWidgets('SVG 明确提示不可编辑，可返回', (tester) async {
    final store = _FakeStore(db, root);
    await _open(
      tester,
      store: store,
      source: _asset('svg', _svgHash, 'svg', 'image/svg+xml'),
    );

    expect(find.textContaining('SVG'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('launchEditor')), findsOneWidget);
  });

  testWidgets('未绘制时保存给出提示且停留在编辑页', (tester) async {
    final store = _FakeStore(db, root);
    ImageEditResult? result;
    await _open(tester, store: store, onResult: (value) => result = value);

    await tester.tap(find.byKey(const ValueKey('editorSave')));
    await tester.pump();

    expect(find.text('请先绘制矩形蒙版或红线标注'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('editorCanvas')), findsOneWidget);
    expect(store.saved, isEmpty);
    expect(result, isNull);
  });

  testWidgets('工具与保存按钮的触控高度不小于 48dp', (tester) async {
    final store = _FakeStore(db, root);
    await _open(tester, store: store);

    for (final key in const [
      'editorUndo',
      'editorRedo',
      'editorClear',
      'editorSave',
      'editorToolMask',
      'editorToolMarkup',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(48),
        reason: key,
      );
    }
  });

  testWidgets('编辑工具随窗口重排并保留编辑历史', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 800);
    addTearDown(tester.view.reset);
    final store = _FakeStore(db, root)
      ..settings['editor:src'] = {
        'mask': [.2, .2, .8, .8],
        'strokes': <Object>[],
      };
    await _open(tester, store: store);
    await tester.tap(find.byKey(const ValueKey('editorClear')));
    await tester.pump();
    final canvas = find.byKey(const ValueKey('editorCanvas'));
    final status = find.byKey(const ValueKey('editorStatus'));
    expect(
      tester.getTopLeft(status).dy,
      greaterThan(tester.getBottomLeft(canvas).dy),
    );

    tester.view.physicalSize = const Size(1100, 350);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(status).dx,
      greaterThan(tester.getTopRight(canvas).dx),
    );
    expect(_statusOf(tester), contains('尚未绘制'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(_statusOf(tester), contains('矩形蒙版'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('恢复草稿后可清空、撤销和重做', (tester) async {
    final store = _FakeStore(db, root)
      ..settings['editor:src'] = {
        'mask': [.2, .2, .8, .8],
        'strokes': <Object>[],
      };
    await _open(tester, store: store);

    expect(_statusOf(tester), contains('矩形蒙版'));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('editorUndo')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('editorClear')));
    await tester.pump();
    expect(_statusOf(tester), contains('尚未绘制'));
    expect(store.settings['editor:src'], const EditorDraft.empty().toJson());

    await tester.tap(find.byKey(const ValueKey('editorUndo')));
    await tester.pump();
    expect(_statusOf(tester), contains('矩形蒙版'));

    await tester.tap(find.byKey(const ValueKey('editorRedo')));
    await tester.pump();
    expect(_statusOf(tester), contains('尚未绘制'));

    await tester.tap(find.byKey(const ValueKey('editorUndo')));
    await tester.pump();
    expect(_statusOf(tester), contains('矩形蒙版'));
  });

  testWidgets('拖动矩形后保存，返回蒙版且 PNG 与源图同尺寸', (tester) async {
    final store = _FakeStore(db, root);
    ImageEditResult? result;
    await _open(tester, store: store, onResult: (value) => result = value);
    final preview = tester.widget<Image>(find.descendant(
      of: find.byType(StudioImage),
      matching: find.byType(Image),
    ));
    expect((preview.image as ResizeImage).imageProvider, isA<FileImage>());

    final center = tester.getCenter(find.byKey(const ValueKey('editorCanvas')));
    await tester.dragFrom(center + const Offset(-30, -20), const Offset(60, 40));
    await tester.pump();
    expect(_statusOf(tester), contains('矩形蒙版'));

    await _saveAndWait(tester);

    expect(result, isNotNull);
    expect(result!.mask, isNotNull);
    expect(result!.markup, isNull);
    expect(result!.mask!.id, 'saved');
    expect(store.saved, hasLength(1));
    expect(store.savedMimes.single, 'image/png');
    final size = await tester.runAsync(() => readImageSize(store.saved.single));
    expect(size, const Size(40, 30));
    expect(store.settings['editor:src'], const EditorDraft.empty().toJson());
  });

  testWidgets('切换到红线标注后自由绘制，保存返回标注层', (tester) async {
    final store = _FakeStore(db, root);
    ImageEditResult? result;
    await _open(tester, store: store, onResult: (value) => result = value);

    await tester.tap(find.byKey(const ValueKey('editorToolMarkup')));
    await tester.pump();
    final center = tester.getCenter(find.byKey(const ValueKey('editorCanvas')));
    await tester.dragFrom(center + const Offset(-40, 0), const Offset(80, -20));
    await tester.pump();
    expect(_statusOf(tester), contains('红线标注：1 笔'));

    await _saveAndWait(tester);

    expect(result!.markup, isNotNull);
    expect(result!.mask, isNull);
    expect(store.savedMimes.single, 'image/png');
    final size = await tester.runAsync(() => readImageSize(store.saved.single));
    expect(size, const Size(40, 30));
  });

  testWidgets('载入现有蒙版时直接返回，不做重复编码', (tester) async {
    final store = _FakeStore(db, root);
    final initialMask = _asset('mask', _otherHash, 'png', 'image/png');
    ImageEditResult? result;
    await _open(
      tester,
      store: store,
      initialMask: initialMask,
      onResult: (value) => result = value,
    );

    expect(_statusOf(tester), contains('已载入现有蒙版'));
    expect(find.textContaining('开始绘制会替换它'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('editorSave')));
    await tester.pumpAndSettle();

    expect(result?.mask?.id, 'mask');
    expect(result?.markup, isNull);
    expect(store.saved, isEmpty);
  });

  testWidgets('保存失败时提示原因并留在编辑页', (tester) async {
    final store = _FakeStore(db, root)..failSave = true;
    ImageEditResult? result;
    await _open(tester, store: store, onResult: (value) => result = value);

    final center = tester.getCenter(find.byKey(const ValueKey('editorCanvas')));
    await tester.dragFrom(center + const Offset(-30, -20), const Offset(60, 40));
    await tester.pump();
    await _saveAndWait(tester);

    expect(find.text('磁盘已满'), findsOneWidget);
    expect(find.byKey(const ValueKey('editorCanvas')), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('保存中阻止重复保存和离开页面', (tester) async {
    final store = _FakeStore(db, root)..saveGate = Completer<void>();
    ImageEditResult? result;
    await _open(tester, store: store, onResult: (value) => result = value);

    final center = tester.getCenter(find.byKey(const ValueKey('editorCanvas')));
    await tester.dragFrom(center + const Offset(-30, -20), const Offset(60, 40));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('editorSave')));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('editorSave')))
          .onPressed,
      isNull,
    );

    unawaited(
      tester.state<NavigatorState>(find.byType(Navigator)).maybePop(),
    );
    await tester.pump();
    expect(find.text('正在保存，请稍候'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('editorCanvas')), findsOneWidget);

    store.saveGate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(store.saved, hasLength(1));
    expect(result, isNotNull);
  });

  testWidgets('单笔点数达到上限时明显提示，不静默丢弃', (tester) async {
    final store = _FakeStore(db, root);
    await _open(tester, store: store);

    await tester.tap(find.byKey(const ValueKey('editorToolMarkup')));
    await tester.pump();
    final center = tester.getCenter(find.byKey(const ValueKey('editorCanvas')));
    final gesture = await tester.startGesture(center);
    // 前几个事件越过拖拽阈值，之后左右往返，保证每个点都超过去重距离。
    for (var i = 0; i < 4100; i++) {
      await gesture.moveBy(Offset(i.isEven ? 2 : -2, 0));
    }
    await tester.pump();

    expect(find.textContaining('单笔最多 4000 个点'), findsAtLeastNWidgets(1));
    await gesture.up();
    await tester.pump();
    expect(_statusOf(tester), contains('红线标注：1 笔'));
  });
}
