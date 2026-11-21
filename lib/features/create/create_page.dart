import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/studio_store.dart';
import '../studio_image.dart';
import '../../models/models.dart';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../data/image_validation.dart';
import '../../api/network_dio.dart';
import '../../platform/local_file_picker.dart';
import '../../tasks/image_download.dart';
import '../editor/image_editor_page.dart';
import 'prompt_library_page.dart';
import 'size_selector.dart';
import '../gallery/gallery_page.dart';
import '../../api/params.dart';
import '../../plugins/plugin_contract.dart';
import '../../plugins/plugin_registry.dart';
import '../plugins/plugin_fields_form.dart';
import 'plugin_chain.dart';

class CreatePage extends StatefulWidget {
  const CreatePage({
    super.key,
    required this.store,
    required this.submit,
    required this.cancel,
    required this.retry,
    this.resumeRemote,
    required this.openProviders,
    required this.openSettings,
    this.seed,
    this.plugins,
  });
  final StudioStore store;
  final Future<void> Function(GenerationInput) submit;
  final Future<void> Function(String) cancel;
  final Future<void> Function(String) retry;
  final Future<void> Function(String)? resumeRemote;
  final VoidCallback openProviders, openSettings;
  final GenerationInput? seed;

  /// 插件运行时；为空时按内置协议能力处理，旧测试无需初始化插件。
  final PluginRegistry? plugins;
  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> with WidgetsBindingObserver {
  final _prompt = TextEditingController();
  final _promptFocus = FocusNode();
  List<ProviderConfig> _providers = [];
  List<ImageAsset> _references = [];
  ImageAsset? _mask, _markup;
  String? _providerId;
  String? _modelOverride;
  String? _responseModelOverride;
  String? _selectedModel(ProviderConfig provider, {bool response = false}) {
    final preferred = response
        ? _responseModelOverride ?? provider.responseModel
        : _modelOverride ??
              (_usesResponseModel ? provider.toolModel : provider.imageModel);
    return provider.enabledModels.contains(preferred)
        ? preferred
        : provider.enabledModels.firstOrNull;
  }

  GenerationInput? _seed;
  GenerationParams _params = const GenerationParams(inputFidelity: '');
  String? _draftRevision;
  bool _draftLoaded = false;
  List<ProcessingStep> _preprocessors = const [];
  List<ProcessingStep> _postprocessors = const [];
  List<ProcessorDescriptor> _processors = const [];

  /// 未注入插件时返回 null，界面退回内置供应商的旧选项。
  GenerationCapabilities? get _capabilities {
    final provider = _provider;
    if (widget.plugins == null || provider == null) return null;
    try {
      return widget.plugins!.capabilities(
        provider,
        hasInputImages: _references.isNotEmpty,
      );
    } on Object {
      return null;
    }
  }

  bool get _usesResponseModel {
    final declared = _capabilities?.usesResponseModel;
    return declared ?? _provider?.protocol == ApiProtocol.responses;
  }

  int get _referenceLimit => referenceLimitFor(
    _capabilities,
    asyncProtocol: _provider?.protocol.isAsync == true,
  );
  Timer? _saveTimer;
  bool _loading = true, _submitting = false, _picking = false;
  String? _error;
  final _sheet = DraggableScrollableController();
  double _minimumExtent = .16, _sheetHeight = 600;
  bool _canCollapse = true;

  void _sheetChanged() {
    final canCollapse = _sheet.size > _minimumExtent + .01;
    if (canCollapse != _canCollapse && mounted)
      setState(() => _canCollapse = canCollapse);
  }

  void _update(VoidCallback change) {
    if (!mounted) return;
    setState(change);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sheet.addListener(_sheetChanged);
    widget.store.addListener(_refreshProviders);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CreatePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seed != null && widget.seed != oldWidget.seed)
      _applySeed(widget.seed!);
  }

  void _applySeed(GenerationInput seed) {
    _update(() {
      _seed = seed;
      _prompt.text = seed.prompt;
      _params = seed.params;
      _references = List.of(seed.references);
      _mask = seed.mask;
      _markup = seed.markup;
      _providerId = seed.provider.id;
      _modelOverride = seed.provider.protocol != ApiProtocol.responses
          ? seed.provider.imageModel
          : seed.provider.toolModel;
      _responseModelOverride = seed.provider.responseModel;
      _preprocessors = List.of(seed.preprocessors);
      _postprocessors = List.of(seed.postprocessors);
    });
    _scheduleSave();
  }

  Future<void> _load({bool restored = false}) async {
    try {
      final (:draft, :revision) = await widget.store.readDraft();
      final selection = await widget.store.setting('selection');
      final providers = await widget.store.providers();
      if (!mounted) return;
      _update(() {
        _draftRevision = revision;
        _draftLoaded = true;
        _mask = null;
        _markup = null;
        _params = const GenerationParams(inputFidelity: '');
        _providers = providers;
        _providerId =
            draft?['providerId'] as String? ??
            selection?['providerId'] as String?;
        _modelOverride = draft?['model'] as String?;
        _responseModelOverride = draft?['responseModel'] as String?;
        _prompt.text = draft?['prompt'] as String? ?? '';
        if (draft?['params'] != null)
          _params = GenerationParams.fromJson(
            Map<String, dynamic>.from(draft!['params'] as Map),
          );
        _references = (draft?['references'] as List? ?? [])
            .map(
              (e) => ImageAsset.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        if (draft?['mask'] != null)
          _mask = ImageAsset.fromJson(
            Map<String, dynamic>.from(draft!['mask'] as Map),
          );
        if (draft?['markup'] != null)
          _markup = ImageAsset.fromJson(
            Map<String, dynamic>.from(draft!['markup'] as Map),
          );
        _preprocessors = (draft?['preprocessors'] as List? ?? [])
            .map(
              (e) =>
                  ProcessingStep.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        _postprocessors = (draft?['postprocessors'] as List? ?? [])
            .map(
              (e) =>
                  ProcessingStep.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
        _processors = widget.plugins?.processors ?? const [];
        _loading = false;
      });
      if (!restored && widget.seed != null) _applySeed(widget.seed!);
    } catch (_) {
      if (mounted)
        _update(() {
          _loading = false;
          _error = '无法读取草稿，请重试';
        });
    }
  }

  Future<void> _refreshProviders() async {
    try {
      if (_draftLoaded && (await widget.store.setting(StudioStore.draftRevisionKey))?['id'] != _draftRevision && mounted) {
        _saveTimer?.cancel();
        await _load(restored: true);
        return;
      }
      final providers = await widget.store.providers();
      _update(() => _providers = providers);
    } catch (_) {
      _update(() => _error = '无法读取供应商，请重试');
    }
  }

  ProviderConfig? get _provider {
    final enabled = _providers.where((p) => p.enabled);
    for (final p in enabled) {
      if (p.id == _providerId) return p;
    }
    return _providerId == null && enabled.isNotEmpty ? enabled.first : null;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_save()),
    );
  }

  Future<void> _urlReference() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(
      text: clipboard?.text?.trim().startsWith('http') == true
          ? clipboard!.text!.trim()
          : '',
    );
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从链接添加参考图'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '图片 URL',
            helperText: '下载完成后保存在本机，不携带 API 密钥',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || !mounted) return;
    _update(() => _picking = true);
    final dio = createNetworkDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 120),
      ),
    );
    try {
      final bytes = await downloadImage(url, downloader: dio);
      final asset = await widget.store.saveAsset(
        bytes,
        detectImageMime(bytes),
        remoteUrl: url,
      );
      if (mounted) {
        _update(() => _references.add(asset));
        _scheduleSave();
      }
    } catch (_) {
      if (mounted) _update(() => _error = '图片链接无法下载或格式无效');
    } finally {
      dio.close();
      if (mounted) _update(() => _picking = false);
    }
  }

  Future<void> _editReference() async {
    final result = await Navigator.push<ImageEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ImageEditorPage(
          store: widget.store,
          source: _references.first,
          initialMask: _mask,
          initialMarkup: _markup,
        ),
      ),
    );
    if (result != null && mounted) {
      _update(() {
        _mask = result.mask;
        _markup = result.markup;
      });
      _scheduleSave();
    }
  }

  Future<void> _save() async {
    try {
      if (!_draftLoaded) return;
      await widget.store.saveDraft({
        'model': _modelOverride,
        'responseModel': _responseModelOverride,
        'prompt': _prompt.text,
        'providerId': _providerId,
        'params': _params.toJson(),
        'mask': _mask?.toJson(),
        'markup': _markup?.toJson(),
        'references': _references.map((e) => e.toJson()).toList(),
        'preprocessors': _preprocessors.map((e) => e.toJson()).toList(),
        'postprocessors': _postprocessors.map((e) => e.toJson()).toList(),
      }, _draftRevision);
    } catch (_) {
      if (mounted) _update(() => _error = '草稿保存失败，请检查存储空间');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _saveTimer?.cancel();
      unawaited(_save());
    }
  }

  void _change(String key, dynamic value) {
    _update(
      () => _params = GenerationParams.fromJson({
        ..._params.toJson(),
        key: value,
      }),
    );
    _scheduleSave();
  }

  /// 链结构变化要重绘；字段表单在 initState 里回报参数，那一刻不能重建。
  void _setChain({required bool pre, required List<ProcessingStep> steps}) {
    if (pre) {
      _preprocessors = List.of(steps);
    } else {
      _postprocessors = List.of(steps);
    }
    _edited();
  }

  void _setExtra(Map<String, dynamic> values) {
    _params = GenerationParams.fromJson({..._params.toJson(), 'extra': values});
    _edited();
  }

  void _edited() {
    _scheduleSave();
    if (!mounted ||
        WidgetsBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks)
      return;
    setState(() {});
  }

  Future<void> _pick() async {
    _update(() => _picking = true);
    try {
      final remaining = _referenceLimit - _references.length;
      final List<XFile> files;
      if (kIsWeb) {
        const extensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'];
        final picked = remaining == 1
            ? [
                ?await FilePicker.pickFile(
                  type: FileType.custom,
                  allowedExtensions: extensions,
                  webOptions: localFilePickerOptions(),
                ),
              ]
            : await FilePicker.pickFiles(
                type: FileType.custom,
                allowedExtensions: extensions,
                webOptions: localFilePickerOptions(),
              );
        for (final file in picked.take(remaining)) {
          final length = file.lengthSync();
          if (length == null || length > 64 * 1024 * 1024) {
            throw const FormatException('无法确认图片大小或图片超过 64 MB');
          }
        }
        files = [for (final file in picked.take(remaining)) file.xFile];
      } else {
        final picker = ImagePicker();
        files = remaining == 1
            ? [?await picker.pickImage(source: ImageSource.gallery)]
            : await picker.pickMultiImage(limit: remaining);
      }
      final added = <ImageAsset>[];
      for (final file in files.take(_referenceLimit - _references.length)) {
        if (await file.length() > 64 * 1024 * 1024)
          throw const FormatException('图片超过 64 MB');
        final extension = file.name.split('.').last.toLowerCase();
        final mime = {
          'jpg': 'image/jpeg',
          'jpeg': 'image/jpeg',
          'png': 'image/png',
          'webp': 'image/webp',
          'gif': 'image/gif',
          if (kIsWeb) 'svg': 'image/svg+xml',
        }[extension];
        if (mime == null)
          throw FormatException(
            kIsWeb
                ? '请选择 PNG、JPEG、WebP、GIF 或 SVG 图片'
                : '请选择 PNG、JPEG、WebP 或 GIF 图片',
          );
        added.add(await widget.store.saveAsset(await file.readAsBytes(), mime));
      }
      if (!mounted) return;
      _update(() => _references = [..._references, ...added]);
      _scheduleSave();
    } catch (error) {
      if (mounted)
        _update(
          () => _error = error is FormatException
              ? error.message
              : '无法读取图片，请重新选择',
        );
    } finally {
      if (mounted) _update(() => _picking = false);
    }
  }

  Future<void> _generate() async {
    if (_params.size.isEmpty) {
      _update(() => _error = '请输入有效的自定义分辨率');
      return;
    }
    final provider = _provider;
    if (provider == null) {
      widget.openProviders();
      return;
    }
    _update(() {
      _submitting = true;
      _error = null;
    });
    try {
      if ((await widget.store.apiKey(provider.id, baseUrl: provider.baseUrl))?.trim().isNotEmpty != true) {
        widget.openProviders();
        return;
      }
      await _save();
      final model = _selectedModel(provider);
      final responseModel = _selectedModel(provider, response: true);
      if (model == null || (_usesResponseModel && responseModel == null))
        throw const FormatException('请先在供应商模型页启用模型');
      final selectedProvider = ProviderConfig.fromJson({
        ...provider.toJson(),
        (_usesResponseModel ? 'toolModel' : 'imageModel'): model,
        if (_usesResponseModel) 'responseModel': responseModel,
      });
      final id = newId();
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      for (final step in [..._preprocessors, ..._postprocessors]) {
        final processor = findProcessor(_processors, step);
        final invalid = processor == null
            ? '找不到处理器「${step.processorId}」'
            : validatePluginFieldValues(processor.fields, step.params);
        if (invalid != null)
          throw FormatException('$invalid（${describeStep(_processors, step)}）');
      }
      if (_preprocessors.isNotEmpty && _references.isEmpty)
        throw const FormatException('预处理需要至少一张参考图');
      final capabilities = _capabilities;
      await widget.submit(
        GenerationInput(
          taskId: id,
          provider: selectedProvider,
          prompt: _prompt.text.trim(),
          params: _params,
          references: List.of(_references),
          parentTaskId: _seed?.parentTaskId,
          parentAssetId: _seed?.parentAssetId,
          mask: capabilities?.supportsMask == false ? null : _mask,
          markup: capabilities?.supportsMarkup == false ? null : _markup,
          preprocessors: List.of(_preprocessors),
          postprocessors: List.of(_postprocessors),
        ),
      );
      if (mounted) await _collapseComposer();
    } catch (error) {
      if (mounted)
        _update(
          () => _error = error is FormatException
              ? error.message
              : error is StateError
              ? error.message
              : '提交失败，请检查供应商设置',
        );
    } finally {
      if (mounted) _update(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_refreshProviders);
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    unawaited(_save());
    _sheet.dispose();
    _promptFocus.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        final bottomSafe = MediaQuery.paddingOf(context).bottom;
        return PopScope(
          canPop: wide || !_canCollapse,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && !wide) unawaited(_collapseComposer());
          },
          child: Stack(
            children: [
              GalleryPage(
                store: widget.store,
                reuse: _reuse,
                retry: widget.retry,
                resumeRemote: widget.resumeRemote,
                cancel: widget.cancel,
                title: 'Pixdraft',
                headerActions: [
                  IconButton(
                    tooltip: '提示词库',
                    onPressed: _promptLibrary,
                    icon: const Icon(Icons.bookmarks_outlined),
                  ),
                  IconButton(
                    tooltip: '设置',
                    onPressed: widget.openSettings,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
                composer: wide ? null : SizedBox(height: 96 + bottomSafe),
                sidebar: wide
                    ? SizedBox(
                        width: (constraints.maxWidth * .32).clamp(340.0, 420.0),
                        child: _wideComposer(context),
                      )
                    : null,
              ),
              if (!wide)
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomInset),
                    child: SafeArea(
                      bottom: false,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _sheetHeight = constraints.maxHeight;
                          _minimumExtent = ((96 + bottomSafe) / _sheetHeight)
                              .clamp(.12, .5);
                          return DraggableScrollableSheet(
                            key: const ValueKey('persistent-composer'),
                            controller: _sheet,
                            initialChildSize: _canCollapse
                                ? .5
                                : _minimumExtent,
                            minChildSize: _minimumExtent,
                            maxChildSize: .94,
                            snap: true,
                            snapSizes: const [.5],
                            shouldCloseOnMinExtent: false,
                            builder: (context, scrollController) => Material(
                              color: Theme.of(context).colorScheme.surface,
                              elevation: 8,
                              clipBehavior: Clip.antiAlias,
                              shape: RoundedRectangleBorder(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(24),
                                ),
                                side: BorderSide(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, panel) {
                                  final showContent =
                                      panel.maxHeight >= 240 ||
                                      (_sheetHeight < 480 &&
                                          panel.maxHeight >
                                              _sheetHeight * _minimumExtent +
                                                  4);
                                  final pinSubmit = panel.maxHeight >= 220;
                                  return Column(
                                    children: [
                                      GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onVerticalDragUpdate: (details) =>
                                            _sheet.jumpTo(
                                              (_sheet.size -
                                                      details.delta.dy /
                                                          _sheetHeight)
                                                  .clamp(_minimumExtent, .94),
                                            ),
                                        onVerticalDragEnd: (details) {
                                          final velocity =
                                              details.primaryVelocity ?? 0;
                                          final target = velocity > 500
                                              ? _minimumExtent
                                              : velocity < -500
                                              ? .94
                                              : [
                                                  _minimumExtent,
                                                  .5,
                                                  .94,
                                                ].reduce(
                                                  (a, b) =>
                                                      (a - _sheet.size).abs() <
                                                          (b - _sheet.size)
                                                              .abs()
                                                      ? a
                                                      : b,
                                                );
                                          unawaited(
                                            target == _minimumExtent
                                                ? _collapseComposer()
                                                : _resizeComposer(target),
                                          );
                                        },
                                        child: InkWell(
                                          key: const ValueKey('open-composer'),
                                          onTap: _openComposer,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              20,
                                              10,
                                              8,
                                              4,
                                            ),
                                            child: Column(
                                              children: [
                                                Container(
                                                  width: 44,
                                                  height: 4,
                                                  decoration: BoxDecoration(
                                                    color: Theme.of(context)
                                                        .dividerColor,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                  ),
                                                ),
                                                const SizedBox(height: 6),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Text(
                                                            '写提示词',
                                                            style:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .textTheme
                                                                    .titleMedium,
                                                          ),
                                                          if (!showContent)
                                                            Text(
                                                              _prompt.text
                                                                      .trim()
                                                                      .isEmpty
                                                                  ? '向上展开，添加参考图和调整参数'
                                                                  : _prompt.text
                                                                        .trim(),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style:
                                                                  Theme.of(
                                                                        context,
                                                                      )
                                                                      .textTheme
                                                                      .bodySmall,
                                                            ),
                                                        ],
                                                      ),
                                                    ),
                                                    if (showContent)
                                                      IconButton(
                                                        tooltip: '提示词库',
                                                        onPressed:
                                                            _promptLibrary,
                                                        icon: const Icon(
                                                          Icons
                                                              .bookmarks_outlined,
                                                        ),
                                                      ),
                                                    IconButton(
                                                      tooltip: showContent
                                                          ? '收起输入面板'
                                                          : '展开输入面板',
                                                      onPressed: showContent
                                                          ? _collapseComposer
                                                          : _openComposer,
                                                      icon: Icon(
                                                        showContent
                                                            ? Icons
                                                                  .keyboard_arrow_down
                                                            : Icons
                                                                  .keyboard_arrow_up,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const Divider(height: 1),
                                      Expanded(
                                        child: ExcludeFocus(
                                          excluding: !showContent,
                                          child: Offstage(
                                            offstage: !showContent,
                                            child: SingleChildScrollView(
                                              controller: scrollController,
                                              keyboardDismissBehavior:
                                                  ScrollViewKeyboardDismissBehavior
                                                      .onDrag,
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                    20,
                                                    16,
                                                    20,
                                                    12,
                                                  ),
                                              child: Column(
                                                children: [
                                                  _composerContent(),
                                                  if (!pinSubmit)
                                                    _submitControls(context),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (showContent && pinSubmit)
                                        SafeArea(
                                          top: false,
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(
                                              20,
                                              8,
                                              20,
                                              12,
                                            ),
                                            child: _submitControls(context),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _wideComposer(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          _promptFocus.unfocus(),
    },
    child: FocusTraversalGroup(
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pinSubmit = constraints.maxHeight >= 240;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (constraints.maxHeight >= 140)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    child: Text(
                      '创作',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    primary: false,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _composerContent(),
                        if (!pinSubmit) _submitControls(context),
                      ],
                    ),
                  ),
                ),
                if (pinSubmit)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: _submitControls(context),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _submitControls(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      FilledButton.icon(
        key: const ValueKey('submit-generation'),
        onPressed: _submitting ? null : _generate,
        icon: _submitting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.arrow_forward),
        label: Text(_provider == null ? '配置供应商' : '生成 ${_params.count} 张图片'),
      ),
    ],
  );

  void _reuse(GenerationInput input) {
    _applySeed(input);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null)
        Navigator.of(context).popUntil((candidate) => candidate == route);
      unawaited(_openComposer());
    });
  }

  Future<void> _resizeComposer(double extent) async {
    if (!_sheet.isAttached) return;
    await _sheet.animateTo(
      extent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openComposer() => _resizeComposer(.94);

  Future<void> _collapseComposer() async {
    FocusScope.of(context).unfocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _resizeComposer(_minimumExtent);
    _saveTimer?.cancel();
    await _save();
  }

  Widget _composerContent() {
    final provider = _provider;
    final model = provider == null ? '' : _selectedModel(provider) ?? '';
    final capabilities = _capabilities;
    final asyncProtocol = provider?.protocol.isAsync == true;
    final qualityOptions = qualityOptionsFor(
      capabilities,
      asyncProtocol: asyncProtocol,
      model: model,
    );
    final formatOptions = formatOptionsFor(
      capabilities,
      asyncProtocol: asyncProtocol,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('提示词', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text(
              '${_prompt.text.trim().length} 字',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('generation-prompt'),
          controller: _prompt,
          focusNode: _promptFocus,
          minLines: 3,
          maxLines: 6,
          onTap: _openComposer,
          onChanged: (_) {
            unawaited(_openComposer());
            _update(() {});
            _scheduleSave();
          },
          decoration: const InputDecoration(hintText: '描述你想生成的图片…'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('参考图', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            Text('${_references.length}/$_referenceLimit'),
            IconButton(
              tooltip: '添加参考图片',
              onPressed: _picking || _references.length >= _referenceLimit
                  ? null
                  : _pick,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
            IconButton(
              tooltip: '从链接添加参考图',
              onPressed: _picking || _references.length >= _referenceLimit
                  ? null
                  : _urlReference,
              icon: const Icon(Icons.link),
            ),
            if (_references.isNotEmpty)
              IconButton(
                tooltip: '清空参考图',
                onPressed: () {
                  _update(() {
                    _references = [];
                    _mask = null;
                    _markup = null;
                  });
                  _scheduleSave();
                },
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
          ],
        ),
        if (_references.isNotEmpty)
          SizedBox(
            height: 112,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: _references.length,
              onReorderItem: (oldIndex, newIndex) {
                _update(() {
                  final image = _references.removeAt(oldIndex);
                  _references.insert(newIndex, image);
                  if (oldIndex == 0 || newIndex == 0) {
                    _mask = null;
                    _markup = null;
                  }
                });
                _scheduleSave();
              },
              itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
                key: ValueKey('ref-$i-${_references[i].id}'),
                index: i,
                child: SizedBox(
                  width: 104,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () => openImagePreview(
                            context,
                            widget.store,
                            List.of(_references),
                            initialIndex: i,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: StudioImage(
                              store: widget.store,
                              asset: _references[i],
                              fit: BoxFit.cover,
                              cacheWidth: 208,
                              semanticLabel: '参考图 ${i + 1}，点击预览，长按排序',
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.topRight,
                        child: IconButton.filledTonal(
                          tooltip: '移除参考图 ${i + 1}',
                          onPressed: () {
                            _update(() {
                              _references.removeAt(i);
                              if (i == 0) {
                                _mask = null;
                                _markup = null;
                              }
                            });
                            _scheduleSave();
                          },
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_references.isNotEmpty &&
            (capabilities != null
                ? capabilities.supportsMask || capabilities.supportsMarkup
                : provider?.protocol.isAsync != true))
          Wrap(
            children: [
              TextButton.icon(
                onPressed: _editReference,
                icon: const Icon(Icons.draw_outlined),
                label: Text(
                  _mask != null
                      ? '修改蒙版'
                      : _markup != null
                      ? '修改标注'
                      : '编辑首张参考图',
                ),
              ),
              if (_mask != null || _markup != null)
                TextButton(
                  onPressed: () {
                    _update(() {
                      _mask = null;
                      _markup = null;
                    });
                    _scheduleSave();
                  },
                  child: const Text('清除编辑图层'),
                ),
            ],
          ),
        const SizedBox(height: 16),
        Text('生成参数', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.hub_outlined, size: 18),
              label: Text(provider?.name ?? '配置第一个供应商'),
              onPressed: _selectProvider,
            ),
            ActionChip(
              avatar: const Icon(Icons.aspect_ratio, size: 18),
              label: Text('尺寸 ${_params.size == 'auto' ? '自动' : _params.size}'),
              onPressed: _selectSize,
            ),
          ],
        ),
        if (provider != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本次生成模型'),
            subtitle: Text(model.isEmpty ? '尚未启用模型' : model),
            trailing: const Icon(Icons.expand_more),
            onTap: () => _selectModel(),
          ),
        if (provider != null && _usesResponseModel)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Responses 主模型'),
            subtitle: Text(
              _selectedModel(provider, response: true) ?? '尚未启用模型',
            ),
            trailing: const Icon(Icons.expand_more),
            onTap: () => _selectModel(response: true),
          ),
        Row(
          children: [
            Expanded(
              child: _choice(
                '质量',
                qualityOptions.contains(_params.quality)
                    ? _params.quality
                    : 'auto',
                qualityOptions,
                (v) => _change('quality', v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _choice(
                '数量',
                '${_params.count}',
                List.generate(10, (i) => '${i + 1}'),
                (v) => _change('count', int.parse(v)),
              ),
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('更多参数'),
          subtitle: Text(_params.format.toUpperCase()),
          children: [
            _choice(
              '输出格式',
              formatOptions.contains(_params.format)
                  ? _params.format
                  : formatOptions.first,
              formatOptions,
              (v) => _change('format', v),
            ),
            if (provider?.protocol.isAsync != true &&
                ['jpeg', 'webp'].contains(_params.format))
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('压缩质量 ${_params.compression}%'),
                  Slider(
                    value: _params.compression.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 100,
                    label: '${_params.compression}%',
                    onChanged: (v) => _change('compression', v.round()),
                  ),
                ],
              ),
            _choice('背景', _params.background, [
              'auto',
              'opaque',
              'transparent',
            ], (v) => _change('background', v)),
            if (provider?.protocol.isAsync != true)
              _choice('审核', _params.moderation, [
                'auto',
                'low',
              ], (v) => _change('moderation', v)),
            if (_references.isNotEmpty && provider?.protocol.isAsync != true)
              _choice('输入保真度', _params.inputFidelity, [
                '',
                'high',
                'low',
              ], (v) => _change('inputFidelity', v)),
            if (provider?.protocol.isAsync != true)
              _choice('复杂度（供应商扩展）', _params.complexity, [
                '',
                'low',
                'medium',
                'high',
              ], (v) => _change('complexity', v)),
            if (_params.format == 'gif') ...[
              _choice(
                '动画帧数',
                '${_params.gifFrames}',
                List.generate(15, (i) => '${i + 2}'),
                (v) => _change('gifFrames', int.parse(v)),
              ),
              TextFormField(
                initialValue: '${_params.gifDuration}',
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '每帧时长（毫秒）'),
                onChanged: (v) {
                  final n = int.tryParse(v);
                  if (n != null) _change('gifDuration', n);
                },
              ),
            ],
            if ((capabilities?.extraFields ?? const []).isNotEmpty)
              PluginFieldsForm(
                fields: capabilities!.extraFields,
                initial: _params.extra,
                onChanged: _setExtra,
              ),
          ],
        ),
        if (widget.plugins != null) ...[
          const SizedBox(height: 16),
          PluginChainEditor(
            title: '预处理',
            steps: _preprocessors,
            processors: _processors,
            hint: '生成前在本机处理参考图，不调用供应商',
            onChanged: (steps) => _setChain(pre: true, steps: steps),
          ),
          const SizedBox(height: 8),
          PluginChainEditor(
            title: '后处理',
            steps: _postprocessors,
            processors: _processors,
            hint: '结果落盘后在本机处理，失败可只重试本地部分',
            onChanged: (steps) => _setChain(pre: false, steps: steps),
          ),
        ],
      ],
    );
  }

  Future<void> _selectSize() async {
    if (_provider?.protocol.isAsync == true) {
      final size = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final size in [
                'auto',
                ...aspectRatiosFor(_provider!.protocol),
              ])
                ListTile(
                  title: Text(size == 'auto' ? '自动' : size),
                  onTap: () => Navigator.pop(context, size),
                ),
            ],
          ),
        ),
      );
      if (size != null && mounted) _change('size', size);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  MediaQuery.sizeOf(context).height * .85 -
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizeSelector(
                    size: _params.size,
                    onChanged: (value) {
                      _change('size', value);
                      update(() {});
                    },
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _choice(
    String label,
    String value,
    List<String> options,
    ValueChanged<String> changed,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label:$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: options
          .map(
            (v) => DropdownMenuItem(
              value: v,
              child: Text(
                v.isEmpty
                    ? '不发送'
                    : v == 'auto'
                    ? '自动'
                    : v,
              ),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) changed(v);
      },
    ),
  );
  Future<void> _selectModel({bool response = false}) async {
    final provider = _provider;
    if (provider == null) return;
    final model = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (provider.enabledModels.isEmpty)
                const ListTile(title: Text('尚未启用模型，请到供应商模型页添加')),
              for (final id in provider.enabledModels)
                ListTile(
                  title: Text(id),
                  selected: id == _selectedModel(provider, response: response),
                  onTap: () => Navigator.pop(context, id),
                ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理模型'),
                onTap: () {
                  Navigator.pop(context);
                  widget.openProviders();
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (model != null && mounted) {
      _update(() {
        if (response) {
          _responseModelOverride = model;
        } else {
          _modelOverride = model;
        }
      });
      _scheduleSave();
    }
  }

  Future<void> _selectProvider() async {
    if (_providers.where((p) => p.enabled).isEmpty) {
      widget.openProviders();
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in _providers.where((p) => p.enabled))
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                    p.protocol != ApiProtocol.responses
                        ? p.imageModel
                        : '${p.responseModel} / ${p.toolModel}',
                  ),
                  selected: p.id == _provider?.id,
                  trailing: p.id == _provider?.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    _update(() {
                      _providerId = p.id;
                      if (p.protocol.isAsync) {
                        _params = GenerationParams.fromJson({
                          ..._params.toJson(),
                          'size': 'auto',
                          'quality': 'auto',
                          'format': 'png',
                        });
                        _mask = null;
                        _markup = null;
                      }
                      _modelOverride = null;
                      _responseModelOverride = null;
                    });
                    _scheduleSave();
                    Navigator.pop(context);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理供应商'),
                onTap: () {
                  Navigator.pop(context);
                  widget.openProviders();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _promptLibrary() async {
    final prompt = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PromptLibraryPage(store: widget.store, current: _prompt.text),
      ),
    );
    if (prompt != null && mounted) {
      _update(() => _prompt.text = prompt);
      _scheduleSave();
      unawaited(_openComposer());
    }
  }
}
