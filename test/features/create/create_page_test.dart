import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/create/create_page.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStore extends StudioStore {
  _FakeStore({
    List<ProviderConfig> providers = const [],
    Map<String, String> keys = const {},
    List<Map<String, Object?>> prompts = const [],
  }) : _providers = List.of(providers),
       _keys = {...keys},
       _prompts = List.of(prompts),
       super(_UnusedDatabase(), Directory.systemTemp);

  final List<ProviderConfig> _providers;
  final Map<String, String> _keys;
  final List<Map<String, Object?>> _prompts;
  final Map<String, Map<String, dynamic>?> settings = {};
  final List<(String, Map<String, dynamic>)> savedSettings = [];
  List<StudioTask> results = [];
  @override
  Future<List<StudioTask>> tasks() async => results;
  @override
  Future<StudioTask?> task(String id) async => results.where((task) => task.id == id).firstOrNull;
  @override
  Future<List<Map<String, Object?>>> categories() async => [];

  @override
  Future<List<ProviderConfig>> providers() async => List.of(_providers);

  @override
  Future<String?> apiKey(String id, {String? baseUrl}) async => _keys[id];

  @override
  Future<Map<String, dynamic>?> setting(String key) async => settings[key];
  @override
  Future<({Map<String, dynamic>? draft, String? revision})> readDraft() async => (
    draft: settings['draft'], revision: settings[StudioStore.draftRevisionKey]?['id'] as String?,
  );

  @override
  Future<void> saveDraft(Map<String, dynamic> draft, String? revision) async {
    if (revision == settings[StudioStore.draftRevisionKey]?['id']) {
      await saveSetting('draft', draft);
    }
  }

  @override
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    settings[key] = value;
    savedSettings.add((key, value));
  }

  @override
  Future<List<Map<String, Object?>>> prompts() async => List.of(_prompts);
}

ProviderConfig _provider({String id = 'p1', String name = '示例供应商'}) =>
    ProviderConfig(id: id, name: name, baseUrl: 'https://api.example.com/v1');

Future<void> _pump(
  WidgetTester tester, {
  required StudioStore store,
  required Future<void> Function(GenerationInput) submit,
  VoidCallback? openProviders,
  Future<void> Function(String)? cancel,
  Future<void> Function(String)? retry,
  bool expand = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CreatePage(
        store: store,
        submit: submit,
        cancel: cancel ?? (_) async {},
        retry: retry ?? (_) async {},
        openSettings: () {},
        openProviders: openProviders ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (expand) await tester.tap(find.byKey(const ValueKey('open-composer')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('窄屏草稿跨断点保留，宽屏短窗口有常驻创作栏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    await _pump(tester, store: _FakeStore(), submit: (_) async {});
    final prompt = find.byKey(const ValueKey('generation-prompt'));
    await tester.enterText(prompt, '跨屏草稿');
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 330);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-composer')), findsNothing);
    final search = find.widgetWithText(TextField, '搜索提示词、参数、供应商、分类…');
    expect(tester.getTopRight(prompt).dx, lessThan(tester.getTopLeft(search).dx));
    expect(tester.widget<TextField>(prompt).controller!.text, '跨屏草稿');
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(390, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-composer')), findsOneWidget);
    expect(tester.widget<TextField>(prompt).controller!.text, '跨屏草稿');
  });

  testWidgets('收起输入后重试确认或取消、返回详情都不展开面板或改写草稿', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'test'});
    store.results = [StudioTask(input: GenerationInput(taskId: 'failed', provider: _provider(), prompt: '历史任务', params: const GenerationParams()), status: TaskStatus.error, createdAt: DateTime(2026))];
    final retried = <String>[];
    await _pump(tester, store: store, submit: (_) async {}, retry: (id) async => retried.add(id));
    final prompt = find.byKey(const ValueKey('generation-prompt'), skipOffstage: false);
    await tester.enterText(prompt, '未提交的草稿');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起输入面板'));
    await tester.pumpAndSettle();
    final panel = tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer')));
    void expectCollapsed() {
      expect(panel.controller!.size, closeTo(panel.minChildSize, .01));
      expect(tester.widget<TextField>(prompt).controller!.text, '未提交的草稿');
      expect(tester.widget<TextField>(prompt).focusNode!.hasFocus, isFalse);
    }
    expectCollapsed();
    tester.widget<TextField>(prompt).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    expectCollapsed();
    for (final action in ['取消', '重新生成']) {
      await tester.tap(find.byTooltip('重试生成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expectCollapsed();
    }
    expect(retried, ['failed']);
    await tester.tap(find.text('历史任务'));
    await tester.pumpAndSettle();
    for (final action in ['取消', '重新生成']) {
      await tester.tap(find.text('原位重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('原位重试'), findsOneWidget);
      expectCollapsed();
    }
    expect(retried, ['failed', 'failed']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectCollapsed();
    await tester.tap(find.byTooltip('任务操作'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectCollapsed();
    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectCollapsed();
    await tester.tap(find.byTooltip('复用配置'));
    await tester.pumpAndSettle();
    expect(panel.controller!.size, closeTo(.94, .01));
    expect(tester.widget<TextField>(prompt).controller!.text, '历史任务');
    expect(tester.takeException(), isNull);
  });
  testWidgets('半展开面板从详情和提示词库返回时不因恢复焦点展开', (tester) async {
    final store = _FakeStore(providers: [_provider()]);
    store.results = [StudioTask(input: GenerationInput(taskId: 'history', provider: _provider(), prompt: '历史任务', params: const GenerationParams()), status: TaskStatus.done, createdAt: DateTime(2026))];
    await _pump(tester, store: store, submit: (_) async {});
    final prompt = find.byKey(const ValueKey('generation-prompt'));
    await tester.enterText(prompt, '保持半展开的草稿');
    await tester.pumpAndSettle();
    final controller = tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer'))).controller!;
    controller.jumpTo(.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史任务'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.size, closeTo(.5, .01));
    await tester.tap(find.byTooltip('提示词库').first);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(controller.size, closeTo(.5, .01));
    expect(tester.widget<TextField>(prompt).controller!.text, '保持半展开的草稿');
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    expect(controller.size, closeTo(.94, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('从来源任务详情复用后回到主页并展开所选配置', (tester) async {
    final store = _FakeStore(providers: [_provider()]);
    store.results = [
      StudioTask(input: GenerationInput(taskId: 'child', provider: _provider(), prompt: '后续任务', params: const GenerationParams(), parentTaskId: 'parent'), status: TaskStatus.done, createdAt: DateTime(2026)),
      StudioTask(input: GenerationInput(taskId: 'parent', provider: _provider(), prompt: '来源配置', params: const GenerationParams(size: '1024x1024')), status: TaskStatus.done, createdAt: DateTime(2026)),
    ];
    await _pump(tester, store: store, submit: (_) async {});
    await tester.tap(find.byTooltip('收起输入面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('后续任务'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('查看来源任务'));
    await tester.tap(find.text('查看来源任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复用参数'));
    await tester.pumpAndSettle();
    final prompt = find.byKey(const ValueKey('generation-prompt'));
    expect(prompt, findsOneWidget);
    expect(tester.widget<TextField>(prompt).controller!.text, '来源配置');
    expect(find.text('复用参数'), findsNothing);
    expect(tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer'))).controller!.size, closeTo(.94, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板默认常驻可拖动收起，历史可操作且返回键只收起', (tester) async {
    await _pump(tester, store: _FakeStore(), submit: (_) async {}, expand: false);
    final panel = find.byKey(const ValueKey('persistent-composer'));
    final header = find.byKey(const ValueKey('open-composer'));
    final controller = tester.widget<DraggableScrollableSheet>(panel).controller!;
    expect(controller.size, closeTo(.5, .01));
    expect(find.byKey(const ValueKey('generation-prompt')), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.drag(header, const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(controller.size, closeTo(tester.widget<DraggableScrollableSheet>(panel).minChildSize, .01));
    await tester.tap(find.byTooltip('纯图模式'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示任务信息'), findsOneWidget);

    await tester.drag(header, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(controller.size, closeTo(.94, .01));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(find.byTooltip('展开输入面板'), findsOneWidget);
    await tester.tap(find.byTooltip('展开输入面板'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generation-prompt')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('半展开时输入会展开面板，键盘不遮住提示词和生成按钮', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester, store: _FakeStore(), submit: (_) async {}, expand: false);
    final prompt = find.byKey(const ValueKey('generation-prompt'));
    await tester.enterText(prompt, '从半展开面板输入');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    expect(tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer'))).controller!.size, closeTo(.94, .01));
    expect(tester.getBottomRight(prompt).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('submit-generation'))).dy));
    expect(tester.getBottomRight(prompt).dy, greaterThan(tester.getBottomRight(find.byKey(const ValueKey('open-composer'))).dy + 40));
    expect(tester.widget<TextField>(prompt).focusNode!.hasFocus, isTrue);
    expect(tester.getBottomRight(find.byKey(const ValueKey('submit-generation'))).dy, lessThanOrEqualTo(328));
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.byTooltip('收起输入面板'));
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    final panel = tester.widget<DraggableScrollableSheet>(find.byKey(const ValueKey('persistent-composer')));
    expect(panel.controller!.size, closeTo(panel.minChildSize, .01));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('generation-prompt'), skipOffstage: false)).focusNode!.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('从启用列表选择模型并分别提交 Responses 两个角色', (tester) async {
    const provider = ProviderConfig(id: 'p', name: '示例', baseUrl: 'https://example.test/v1', protocol: ApiProtocol.responses, responseModel: 'main', toolModel: 'image-a', models: ['main', 'image-a', 'image-b']);
    final store = _FakeStore(providers: [provider], keys: {'p': 'test'});
    GenerationInput? submitted;
    await _pump(tester, store: store, submit: (value) async => submitted = value);
    await tester.tap(find.text('本次生成模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('image-b'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responses 主模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('main').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成 1 张图片'));
    await tester.pumpAndSettle();
    expect(submitted?.provider.toolModel, 'image-b');
    expect(submitted?.params.inputFidelity, '');
    expect(submitted?.provider.responseModel, 'main');
    expect(store.settings['draft']?['model'], 'image-b');
    expect(store.settings['draft']?['responseModel'], 'main');
  });

  testWidgets('WaveSpeed 创建页读取目录规则并随任务保存选定模型的规则', (tester) async {
    const model = 'example/new-image';
    const provider = ProviderConfig(
      id: 'p1', name: 'WaveSpeed', baseUrl: 'https://api.wavespeed.ai',
      protocol: ApiProtocol.wavespeed, imageModel: model,
    );
    const schema = {
      'properties': {
        'prompt': {'type': 'string'},
        'aspect_ratio': {'type': 'string', 'enum': ['1:1', '8:1']},
      },
      'required': ['prompt', 'aspect_ratio'],
    };
    final store = _FakeStore(providers: [provider], keys: {'p1': 'test'});
    store.settings['wavespeedCatalog:p1'] = {
      'baseUrl': provider.baseUrl,
      'models': {model: schema},
    };
    GenerationInput? submitted;
    await _pump(tester, store: store, submit: (input) async => submitted = input);
    await tester.enterText(find.byKey(const ValueKey('generation-prompt')), '测试目录规则');
    await tester.ensureVisible(find.text('尺寸 自动'));
    await tester.tap(find.text('尺寸 自动'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '16:9'), findsNothing);
    await tester.tap(find.text('更多比例'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '8:1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('submit-generation')));
    await tester.pumpAndSettle();
    expect(submitted?.params.size, '8:1');
    expect(submitted?.provider.pluginConfig['wavespeedImageSchema'], schema);
  });

  testWidgets('切换模型时保留参考图并按新模型检查数量', (tester) async {
    const banana = 'google/nano-banana-2/edit';
    const flux = 'wavespeed-ai/flux-2-pro/edit';
    const provider = ProviderConfig(
      id: 'p1', name: 'WaveSpeed', baseUrl: 'https://api.wavespeed.ai',
      protocol: ApiProtocol.wavespeed, imageModel: banana, models: [banana, flux],
    );
    final store = _FakeStore(providers: [provider], keys: {'p1': 'test'});
    store.settings['draft'] = {
      'references': List.generate(5, (i) => ImageAsset(
        id: 'ref$i', path: 'assets/${(i + 1).toString().padLeft(64, 'a')}.png',
        mime: 'image/png', hash: 'ref$i', bytes: 100,
      ).toJson()),
    };
    await _pump(tester, store: store, submit: (_) async {});
    expect(find.text('5/14'), findsOneWidget);
    await tester.ensureVisible(find.text('本次生成模型'));
    await tester.tap(find.text('本次生成模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(flux));
    await tester.pumpAndSettle();
    expect(find.text('5/3'), findsOneWidget);
    expect(find.text('当前模型最多支持 3 张参考图'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('submit-generation'))).onPressed, isNull);
    await tester.ensureVisible(find.text('尺寸 自动'));
    await tester.tap(find.text('尺寸 自动'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '自定义'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '宽（像素）'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '16:9'), findsNothing);
  });
  testWidgets('空启用列表阻止生成，旧草稿移除的模型不再提交', (tester) async {
    final provider = ProviderConfig.fromJson({..._provider().toJson(), 'models': ['current'], 'imageModel': 'current'});
    final store = _FakeStore(providers: [provider], keys: {'p1': 'test'});
    store.settings['draft'] = {'model': 'removed'};
    GenerationInput? submitted;
    await _pump(tester, store: store, submit: (value) async => submitted = value);
    await tester.tap(find.text('生成 1 张图片'));
    await tester.pumpAndSettle();
    expect(submitted?.provider.imageModel, 'current');
    store._providers[0] = ProviderConfig.fromJson({...provider.toJson(), 'models': <String>[]});
    store.notifyListeners();
    await tester.pumpAndSettle();
    submitted = null;
    await tester.tap(find.byKey(const ValueKey('open-composer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成 1 张图片'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.ensureVisible(find.text('请先在供应商模型页启用模型'));
    expect(find.text('请先在供应商模型页启用模型'), findsOneWidget);
  });
  testWidgets('参考图点击从当前张预览且移除不触发预览', (tester) async {
    final store = _FakeStore();
    final images = List.generate(2, (i) => ImageAsset(id: 'ref$i', path: 'assets/${(i + 1).toString().padLeft(64, 'a')}.png', mime: 'image/png', hash: 'ref$i', bytes: 100));
    store.settings['draft'] = {'references': images.map((a) => a.toJson()).toList()};
    await _pump(tester, store: store, submit: (_) async {});
    await tester.tap(find.bySemanticsLabel('参考图 2，点击预览，长按排序'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭预览'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除参考图 2'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭预览'), findsNothing);
    expect(find.text('1/16'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('提交后面板收起常驻，历史显示进度且可以停止当前任务', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'test'});
    late GenerationInput input;
    String? cancelled;
    await _pump(tester, store: store, submit: (value) async {
      input = value;
      store.results = [StudioTask(input: input, status: TaskStatus.running, createdAt: DateTime(2026))];
      store.notifyListeners();
    }, cancel: (id) async {
      cancelled = id;
      store.results = [StudioTask(input: input, status: TaskStatus.aborted, createdAt: DateTime(2026))];
      store.notifyListeners();
    });
    await tester.tap(find.byKey(const ValueKey('submit-generation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('generation-prompt')), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pumpAndSettle();
    expect(cancelled, input.taskId);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('已取消'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-composer')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('submit-generation')), findsOneWidget);
  });

  testWidgets('历史跟随生成结果刷新，缩略图可以全屏预览', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'test'});
    late GenerationInput input;
    await _pump(tester, store: store, submit: (value) async {
      input = value;
      store.results = [StudioTask(input: input, status: TaskStatus.error, error: '测试失败提示', createdAt: DateTime(2026))];
      store.notifyListeners();
    });
    await tester.tap(find.byKey(const ValueKey('submit-generation')));
    await tester.pumpAndSettle();
    expect(find.text('测试失败提示'), findsOneWidget);
    const asset = ImageAsset(id: 'result', path: 'assets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png', mime: 'image/png', hash: 'test', bytes: 1, width: 100, height: 100);
    store.results = [StudioTask(input: input, status: TaskStatus.done, outputs: [asset], createdAt: DateTime(2026))];
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('测试失败提示'), findsNothing);
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.getSize(find.byType(InteractiveViewer)), tester.view.physicalSize / tester.view.devicePixelRatio);
    await tester.tap(find.byTooltip('关闭预览'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-composer')), findsOneWidget);
  });
  testWidgets('没有供应商时按钮引导配置且不提交', (tester) async {
    final store = _FakeStore();
    var opened = 0;
    final submitted = <GenerationInput>[];
    await _pump(
      tester,
      store: store,
      submit: (input) async => submitted.add(input),
      openProviders: () => opened++,
    );

    expect(find.text('配置第一个供应商'), findsOneWidget);
    expect(find.text('配置供应商'), findsOneWidget);

    await tester.tap(find.text('配置供应商'));
    await tester.pump();

    expect(opened, 1);
    expect(submitted, isEmpty);
  });

  testWidgets('有供应商但没有密钥时先打开供应商设置', (tester) async {
    final store = _FakeStore(providers: [_provider()]);
    var opened = 0;
    final submitted = <GenerationInput>[];
    await _pump(
      tester,
      store: store,
      submit: (input) async => submitted.add(input),
      openProviders: () => opened++,
    );

    expect(find.text('生成 1 张图片'), findsOneWidget);
    await tester.tap(find.text('生成 1 张图片'));
    await tester.pump();
    await tester.pump();

    expect(opened, 1);
    expect(submitted, isEmpty);
    expect(find.text('配置供应商'), findsNothing);
  });

  testWidgets('填写提示词后提交生成任务', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'sk-test'});
    final submitted = <GenerationInput>[];
    await _pump(
      tester,
      store: store,
      submit: (input) async => submitted.add(input),
    );

    await tester.enterText(find.byKey(const ValueKey('generation-prompt')), '一只猫在雪山');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('生成 1 张图片'));
    await tester.pump();
    await tester.pump();

    expect(submitted, hasLength(1));
    expect(submitted.single.prompt, '一只猫在雪山');
    expect(submitted.single.provider.id, 'p1');
    expect(submitted.single.params.count, 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('generation-prompt')), findsNothing);

    // 等 SnackBar 自动关闭，避免用例结束时留有定时器。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('提交校验失败时在页面显示原因', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'sk-test'});
    await _pump(
      tester,
      store: store,
      submit: (_) async => throw const FormatException('请输入提示词或选择参考图片'),
    );

    await tester.tap(find.text('生成 1 张图片'));
    await tester.pump();
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('请输入提示词或选择参考图片'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('请输入提示词或选择参考图片'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '生成 1 张图片'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('从提示词库选择内容后回到创作并用于提交', (tester) async {
    final store = _FakeStore(
      providers: [_provider()],
      keys: {'p1': 'sk-test'},
      prompts: [
        {'id': 'p1', 'title': '雪山', 'content': '白雪覆盖的山峰'},
      ],
    );
    final submitted = <GenerationInput>[];
    await _pump(
      tester,
      store: store,
      submit: (input) async => submitted.add(input),
    );

    await tester.enterText(find.byKey(const ValueKey('generation-prompt')), '旧提示词');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('提示词库').last);
    await tester.pumpAndSettle();
    expect(find.text('提示词库'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, '雪山'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));

    final field = tester.widget<TextField>(find.byKey(const ValueKey('generation-prompt')));
    expect(field.controller?.text, '白雪覆盖的山峰');

    await tester.tap(find.text('生成 1 张图片'));
    await tester.pump();
    await tester.pump();

    expect(submitted.single.prompt, '白雪覆盖的山峰');
    expect(store.savedSettings.last.$2['prompt'], '白雪覆盖的山峰');

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('小屏下创作页无溢出且提交按钮可见', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'sk-test'});
    await _pump(tester, store: store, submit: (_) async {});

    expect(find.text('生成 1 张图片'), findsOneWidget);
    expect(find.byTooltip('提示词库').last, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('尺寸面板即时更新实际尺寸，收起展开保留草稿', (tester) async {
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'test'});
    await _pump(tester, store: store, submit: (_) async {});
    await tester.enterText(find.byKey(const ValueKey('generation-prompt')), '草稿里的海边');
    await tester.ensureVisible(find.text('尺寸 自动'));
    await tester.tap(find.text('尺寸 自动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('16:9'));
    await tester.pumpAndSettle();
    expect(find.textContaining('实际请求：'), findsOneWidget);
    expect(find.textContaining('自动比例和分辨率'), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起输入面板'));
    await tester.pumpAndSettle();
    expect(find.text('草稿里的海边'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-composer')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('generation-prompt'))).controller!.text, '草稿里的海边');
    expect(store.settings['draft']!['params']['size'], isNot('auto'));
    expect(tester.takeException(), isNull);
  });

  for (final protocol in [ApiProtocol.evolink, ApiProtocol.wavespeed]) {
    testWidgets('${protocol.name} 比例按钮显示预览并保留所选比例', (tester) async {
      final store = _FakeStore(
        providers: [
          ProviderConfig(
            id: 'p1',
            name: protocol.label,
            baseUrl: 'https://api.example.com/v1',
            protocol: protocol,
            imageModel: protocol == ApiProtocol.wavespeed ? 'bytedance/seedream-v5.5/edit' : 'doubao-seedream-5.5',
          ),
        ],
        keys: {'p1': 'test'},
      );
      await _pump(tester, store: store, submit: (_) async {});

      Future<void> openSizes(String size) async {
        final button = find.text('尺寸 $size');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
      }

      await openSizes('自动');
      final wide = find.widgetWithText(ChoiceChip, '16:9');
      expect(tester.widget<ChoiceChip>(wide).avatar, isA<SizedBox>());
      expect(find.text('自定义'), protocol == ApiProtocol.evolink ? findsOneWidget : findsNothing);
      expect(find.text('分辨率档位'), findsNothing);
      await tester.tap(find.text('更多比例'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(ChoiceChip, '1:3'),
        protocol == ApiProtocol.wavespeed ? findsOneWidget : findsNothing,
      );
      final ratio = find.widgetWithText(ChoiceChip, '21:9');
      await tester.ensureVisible(ratio);
      await tester.tap(ratio);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(ratio).selected, isTrue);
      final done = find.text('完成');
      await tester.ensureVisible(done);
      await tester.tap(done);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.settings['draft']!['params']['size'], '21:9');

      await openSizes('21:9');
      expect(tester.widget<ChoiceChip>(ratio).selected, isTrue);
    });
  }

  testWidgets('键盘展开时抽屉仍能提交，失败保留输入', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = _FakeStore(providers: [_provider()], keys: {'p1': 'test'});
    await _pump(tester, store: store, submit: (_) async => throw StateError('提交测试失败'));
    await tester.enterText(find.byKey(const ValueKey('generation-prompt')), '保留这段提示词');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('submit-generation'));
    expect(tester.getBottomRight(button).dy, lessThanOrEqualTo(328));
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('提交测试失败'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('generation-prompt'))).controller!.text, '保留这段提示词');
    expect(tester.takeException(), isNull);
  });
}
