import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/editor/editor_export.dart';
import 'package:image_gen/features/gallery/gallery_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore(this.taskList, [Directory? root]) : super(_UnusedDatabase(), root ?? Directory.systemTemp);

  final List<StudioTask> taskList;

  @override
  Future<List<StudioTask>> tasks() async => List.of(taskList);
  @override
  Future<StudioTask?> task(String id) async => taskList.where((task) => task.id == id).firstOrNull;

  @override
  Future<List<Map<String, Object?>>> categories() async => const [];
  final Map<String, Map<String, dynamic>> settings = {};
  final List<Uint8List> saved = [];

  @override
  Future<Map<String, dynamic>?> setting(String key) async => settings[key];

  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    settings[key] = value;
  }

  @override
  Future<ImageAsset> saveAsset(Uint8List bytes, String mime, {String? remoteUrl}) async {
    saved.add(bytes);
    return ImageAsset(id: 'saved', path: 'assets/${_hash('saved')}.png', mime: mime, hash: _hash('saved'), bytes: bytes.length);
  }
  @override
  Future<void> updateTask(String id, Map<String, Object?> values) async {
    final index = taskList.indexWhere((task) => task.id == id);
    final task = taskList[index];
    taskList[index] = StudioTask(input: task.input, status: task.status, createdAt: task.createdAt, outputs: task.outputs, favorite: values.containsKey('favorite') ? values['favorite'] == 1 : task.favorite, categoryId: values.containsKey('category_id') ? values['category_id'] as String? : task.categoryId, deletedAt: values.containsKey('deleted_at') ? DateTime.tryParse(values['deleted_at'] as String? ?? '') : task.deletedAt);
    notifyListeners();
  }
  @override
  Future<void> purgeTask(String id) async {
    taskList.removeWhere((task) => task.id == id);
    notifyListeners();
  }
}

final _provider = ProviderConfig(
  id: 'p1',
  name: '示例供应商',
  baseUrl: 'https://api.example.com/v1',
);

String _hash(String id) => id.padRight(64, '0');

ImageAsset _asset(String id) => ImageAsset(
  id: id,
  path: 'assets/${_hash(id)}.png',
  mime: 'image/png',
  hash: _hash(id),
  bytes: 128,
  width: 1024,
  height: 768,
);

StudioTask _task(
  String id, {
  String prompt = '一只猫',
  TaskStatus status = TaskStatus.done,
  List<ImageAsset> outputs = const [],
}) => StudioTask(
  input: GenerationInput(
    taskId: id,
    provider: _provider,
    prompt: prompt,
    params: const GenerationParams(),
  ),
  status: status,
  createdAt: DateTime(2026, 1, 1),
  outputs: outputs,
);

class _Harness {
  final reused = <GenerationInput>[];
  final retried = <String>[];
  final cancelled = <String>[];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required List<StudioTask> tasks,
  bool settle = true,
  Directory? root,
}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: GalleryPage(
        store: _FakeStore(tasks, root),
        reuse: harness.reused.add,
        retry: (id) async => harness.retried.add(id),
        cancel: (id) async => harness.cancelled.add(id),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // 运行中的任务带无限 LinearProgressIndicator，不能 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
  return harness;
}

/// 详情页比默认 800x600 高，放大视口避免测试里滚动翻页控件。
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('任务在宽屏并排，缩窄保留选择', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 760);
    addTearDown(tester.view.reset);
    await _pump(tester, tasks: [_task('a'), _task('b')]);
    final cards = [for (final id in ['a', 'b']) find.byKey(ValueKey('task-$id-card'))];
    final wide = cards.map(tester.getTopLeft).toList();
    expect(wide.first.dy, wide.last.dy);
    expect(wide.first.dx, isNot(wide.last.dx));
    await tester.longPress(cards.first);
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    tester.view.physicalSize = const Size(390, 760);
    await tester.pumpAndSettle();
    final narrow = cards.map(tester.getTopLeft).toList();
    expect(narrow.first.dx, narrow.last.dx);
    expect(narrow.first.dy, lessThan(narrow.last.dy));
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('状态筛选可以回到全部，搜索清空恢复历史', (tester) async {
    await _pump(tester, tasks: [_task('a', prompt: '成功任务'), _task('b', prompt: '失败任务', status: TaskStatus.error)]);
    await tester.tap(find.byTooltip('筛选状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('失败').last);
    await tester.pumpAndSettle();
    expect(find.text('成功任务'), findsNothing);
    expect(find.text('失败任务'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部状态').last);
    await tester.pumpAndSettle();
    expect(find.text('成功任务'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets('窄屏历史卡片使用图标操作，恢复与永久删除保留原行为', (tester) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tasks = [_task('a', outputs: [_asset('a1')])];
    await _pump(tester, tasks: tasks);
    final card = find.byType(Card);
    for (final label in ['复用配置', '编辑输出', '重试生成', '移入回收站']) {
      final button = find.descendant(of: card, matching: find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == label));
      expect(button, findsOneWidget);
      expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
    }
    expect(tester.getTopLeft(find.byTooltip('复用配置')).dy, tester.getTopLeft(find.byTooltip('任务操作')).dy);
    expect(find.descendant(of: card, matching: find.byType(TextButton)), findsNothing);
    await tester.longPress(find.byTooltip('复用配置'));
    await tester.pumpAndSettle();
    expect(find.text('复用配置'), findsOneWidget);
    await tester.tap(find.byTooltip('移入回收站'));
    await tester.pumpAndSettle();
    expect(tasks.single.deletedAt, isNotNull);
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('恢复记录'));
    await tester.pumpAndSettle();
    expect(tasks.single.deletedAt, isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移入回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('永久删除'));
    await tester.pumpAndSettle();
    expect(tasks, hasLength(1));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tasks, hasLength(1));
    await tester.tap(find.byTooltip('永久删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(tasks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史复用与重试按原任务执行，批量收藏后移入回收站', (tester) async {
    final tasks = [_task('a', prompt: '山'), _task('b', prompt: '海')];
    final harness = await _pump(tester, tasks: tasks);
    await tester.tap(find.byTooltip('复用配置').first);
    expect(harness.reused.single.taskId, 'a');
    await tester.tap(find.byTooltip('重试生成').first);
    await tester.pumpAndSettle();
    expect(harness.retried, isEmpty);
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    expect(harness.retried, ['a']);
    await tester.tap(find.byTooltip('选择任务').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量收藏'));
    await tester.pumpAndSettle();
    expect(tasks.every((task) => task.favorite), isTrue);
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移入回收站'));
    await tester.pumpAndSettle();
    expect(tasks.every((task) => task.deletedAt != null), isTrue);
    expect(find.byType(Card), findsNothing);
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择任务').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('全选当前结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    expect(tasks, hasLength(2));
    await tester.tap(find.text('永久删除').last);
    await tester.pumpAndSettle();
    expect(tasks, isEmpty);
    expect(find.textContaining('回收站为空'), findsOneWidget);
  });
  testWidgets('输出减少后详情同步当前页与图片操作', (tester) async {
    _tallView(tester);
    final tasks = [_task('t1', outputs: [_asset('a1'), _asset('a2'), _asset('a3')])];
    await _pump(tester, tasks: tasks);
    final store = tester.widget<GalleryPage>(find.byType(GalleryPage)).store;
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    tasks[0] = _task('t1', outputs: [_asset('a1'), _asset('a2')]);
    store.refresh();
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(pager.controller!.page, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets('详情和全屏首尾可用按钮及滑动循环，图片操作跟随当前页', (tester) async {
    _tallView(tester);
    final harness = await _pump(tester, tasks: [_task('t1', outputs: [_asset('a1'), _asset('a2'), _asset('a3')])]);
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    Future<void> turn(String label, String counter) async {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      expect(find.text(counter), findsOneWidget);
    }
    await turn('上一张', '3/3');
    tester.view.physicalSize = const Size(1200, 1000);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    final imageArea = tester.getRect(find.byType(PageView));
    expect(tester.getTopLeft(find.text('一只猫')).dx, greaterThan(imageArea.right));
    tester.view.physicalSize = const Size(800, 1400);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    await turn('下一张', '1/3');
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(PageView), matching: find.byType(Image)).first);
    await tester.pumpAndSettle();
    await turn('上一张', '3/3');
    await turn('下一张', '1/3');
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await turn('下一张', '2/3');
      await turn('下一张', '3/3');
      await turn('下一张', '1/3');
    }
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    await turn('上一张', '3/3');
    await tester.tap(find.text('作为参考图'));
    await tester.pumpAndSettle();
    expect(harness.reused.single.parentAssetId, 'a3');
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏放大后拖动不翻页，还原后恢复翻页，切图重置缩放', (tester) async {
    await _pump(tester, tasks: [_task('t1', outputs: [_asset('a1'), _asset('a2')])]);
    await tester.tap(find.descendant(of: find.byType(Card), matching: find.byType(Image)).first);
    await tester.pumpAndSettle();
    InteractiveViewer image() => tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first);
    Future<void> doubleTap() async {
      final center = tester.getCenter(find.byType(InteractiveViewer).first);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
    }
    await doubleTap();
    expect(image().transformationController!.value.getMaxScaleOnAxis(), 3);
    final before = image().transformationController!.value.clone();
    await tester.drag(find.byType(InteractiveViewer).first, const Offset(-200, 40));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(image().transformationController!.value, isNot(before));
    await doubleTap();
    expect(image().transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    await doubleTap();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(image().transformationController!.value.getMaxScaleOnAxis(), 1);

    final center = tester.getCenter(find.byType(InteractiveViewer).first);
    final first = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final second = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await first.moveBy(const Offset(-60, 0));
    await second.moveBy(const Offset(60, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    expect(image().transformationController!.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('单图不显示翻页控件，输出数量变化后仍可循环', (tester) async {
    _tallView(tester);
    final tasks = [_task('t1', outputs: [_asset('a1')])];
    await _pump(tester, tasks: tasks);
    final store = tester.widget<GalleryPage>(find.byType(GalleryPage)).store;
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('上一张'), findsNothing);
    await tester.tap(find.descendant(of: find.byType(PageView), matching: find.byType(Image)).first);
    await tester.pumpAndSettle();
    expect(find.byTooltip('下一张'), findsNothing);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    tasks[0] = _task('t1', outputs: [_asset('a1'), _asset('a2')]);
    store.refresh();
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byTooltip('上一张'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    tasks[0] = _task('t1', outputs: [_asset('a1')]);
    store.refresh();
    await tester.pumpAndSettle();
    expect(find.byTooltip('下一张'), findsNothing);
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存当前输出时禁用重复点击，完成后显示成功反馈', (tester) async {
    _tallView(tester);
    final result = Completer<bool>();
    var calls = 0;
    const channel = MethodChannel('image_gen/media');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.arguments['path'], endsWith('/assets/${_hash('a2')}.png'));
      return result.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await _pump(tester, tasks: [_task('t1', outputs: [_asset('a1'), _asset('a2')])]);
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到设备'));
    await tester.pump();
    expect(calls, 1);
    final button = find.widgetWithText(TextButton, '正在保存…');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await tester.tap(button);
    await tester.pump();
    expect(calls, 1);
    result.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('图片已保存'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '保存到设备')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('gallery_page_test_');
    final assets = Directory('${root.path}/assets');
    await assets.create();
    // 编辑输出需要真实 PNG 才能进入编辑器画布。
    await File('${assets.path}/${_hash('a1')}.png').writeAsBytes(await encodeMask(40, 30, const Rect.fromLTRB(.4, .4, .6, .6)));
  });

  tearDownAll(() => root.delete(recursive: true));

  testWidgets('回收站图标打开独立页面且可以返回作品', (tester) async {
    await _pump(tester, tasks: [_task('t1')]);
    expect(find.text('管理分类'), findsNothing);
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('回收站为空，删除的作品会保留 15 天'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('作品'), findsOneWidget);
    expect(find.text('一只猫'), findsOneWidget);
  });
  testWidgets('纯图模式展示每个任务的全部输出', (tester) async {
    await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a2')]),
        _task('t2', prompt: '海边', outputs: [_asset('a3')]),
      ],
    );
    expect(find.byType(Image), findsNWidgets(2)); // 列表模式每任务只显示首图

    await tester.tap(find.byTooltip('纯图模式'));
    await tester.pump();

    expect(find.byType(Image), findsNWidgets(3));
    expect(find.byTooltip('显示任务信息'), findsOneWidget);
    expect(find.text('一只猫'), findsNothing);
    expect(find.text('海边'), findsNothing);
  });

  testWidgets('纯图模式没有图片时提示切换任务模式', (tester) async {
    await _pump(
      tester,
      tasks: [_task('t1', status: TaskStatus.running)],
      settle: false,
    );

    await tester.tap(find.byTooltip('纯图模式'));
    await tester.pump();

    expect(find.text('任务尚无图片，请切换任务模式查看进度'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('搜索按提示词或供应商过滤作品', (tester) async {
    await _pump(
      tester,
      tasks: [
        _task('t1', prompt: '雪山'),
        _task('t2', prompt: '海边'),
      ],
    );
    expect(find.byType(Card), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), '雪山');
    await tester.pump();
    expect(find.descendant(of: find.byType(Card), matching: find.text('雪山')), findsOneWidget);
    expect(find.text('海边'), findsNothing);

    await tester.enterText(find.byType(TextField), '示例供应商');
    await tester.pump();
    expect(find.byType(Card), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), '不存在的词');
    await tester.pump();
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('详情页取消运行中的任务', (tester) async {
    final harness = await _pump(
      tester,
      tasks: [_task('t1', status: TaskStatus.running)],
      settle: false,
    );

    await tester.tap(find.text('一只猫'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('取消任务'));
    await tester.pump();
    await tester.pump();

    expect(harness.cancelled, ['t1']);
  });

  testWidgets('详情页确认后原位重试并可复用参数', (tester) async {
    final harness = await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1')]),
      ],
    );

    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('原位重试'));
    await tester.pumpAndSettle();
    expect(find.text('重新生成？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '重新生成'));
    await tester.pumpAndSettle();
    expect(harness.retried, ['t1']);

    await tester.tap(find.text('复用参数'));
    await tester.pumpAndSettle();

    expect(harness.reused, hasLength(1));
    expect(harness.reused.single.prompt, '一只猫');
    expect(find.text('作品'), findsOneWidget); // 已返回作品页
  });

  testWidgets('小屏纯图网格不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a2'), _asset('a3')]),
      ],
    );
    await tester.tap(find.byTooltip('纯图模式'));
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('纯图模式点击第二张直接定位到该输出', (tester) async {
    await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a1'), _asset('a3')]),
      ],
    );
    await tester.tap(find.byTooltip('纯图模式'));
    await tester.pump();

    await tester.tap(find.byType(Image).at(1));
    await tester.pumpAndSettle();

    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('一只猫'), findsOneWidget);
  });

  testWidgets('详情用按钮和滑动连续浏览多个输出', (tester) async {
    _tallView(tester);
    await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a2'), _asset('a3')]),
      ],
    );
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);

    await tester.tap(find.byTooltip('上一张'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('详情打开全屏预览并沿用当前输出连续浏览', (tester) async {
    _tallView(tester);
    await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a2'), _asset('a3')]),
      ],
    );
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下一张'));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .descendant(of: find.byType(PageView), matching: find.byType(Image))
          .first,
    );
    await tester.pumpAndSettle();

    final viewer = find.byType(Scaffold).last;
    expect(
      find.descendant(of: viewer, matching: find.text('2/3')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(of: viewer, matching: find.byTooltip('下一张')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: viewer, matching: find.text('3/3')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(find.byType(PageView), findsOneWidget);
  });

  testWidgets('编辑输出后带蒙版与来源信息回到创作', (tester) async {
    _tallView(tester);
    final harness = await _pump(
      tester,
      tasks: [
        _task('t1', outputs: [_asset('a1'), _asset('a2')]),
      ],
      root: root,
    );
    await tester.tap(find.text('一只猫'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑这张'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 10; i++) {
      if (find.byKey(const ValueKey('editorCanvas')).evaluate().isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('editorCanvas')), findsOneWidget);

    final center = tester.getCenter(
      find.byKey(const ValueKey('editorCanvas')),
    );
    await tester.dragFrom(center + const Offset(-30, -20), const Offset(60, 40));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('editorSave')));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(harness.reused, hasLength(1));
    final input = harness.reused.single;
    expect(input.mask, isNotNull);
    expect(input.markup, isNull);
    expect(input.references.single.id, 'a1');
    expect(input.parentTaskId, 't1');
    expect(input.parentAssetId, 'a1');
    expect(find.text('作品'), findsOneWidget);
  });
}
