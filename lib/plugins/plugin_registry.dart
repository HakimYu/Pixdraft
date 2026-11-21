import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/studio_store.dart';
import '../models/models.dart';
import 'builtin_providers.dart';
import 'local_processing.dart';
import 'plugin_contract.dart';
import 'plugin_manager.dart';
import 'plugin_manifest.dart';
import 'plugin_runtime.dart';
import 'script_provider.dart';

/// 适配器与处理器路由。任务取消只作用于它实际拿到的那个 client。
class PluginRegistry implements GenerationClient {
  PluginRegistry._(
    this.store,
    this.manager,
    this._providers,
    this._processors,
    this._tools,
    this._scripts,
  );

  /// 读取启用状态与已安装版本，注册内置扩展并加载动态插件。
  static Future<PluginRegistry> load(StudioStore store) async {
    final manager = PluginManager(store);
    final registry = PluginRegistry._(store, manager, [], [], [], []);
    final installed = await manager.list();
    final enabled = {for (final plugin in installed) plugin.id: plugin.enabled};

    // 内置插件禁用后不再是新任务的可选项；实例仍注册，已 pin 的任务可以跑完。
    for (final pluginId in builtinPluginIds) {
      if (enabled[pluginId] == false) registry._disabled.add(pluginId);
    }
    for (final provider in createBuiltinProviders(store)) {
      registry._addProvider(provider);
    }
    for (final processor in createBuiltinProcessors()) {
      registry._addProcessor(processor);
    }
    for (final tool in builtinTools()) {
      registry._addTool(tool);
    }

    // 磁盘上的版本全部登记：启用的立即编译，禁用/已卸载的留待 pin 任务按需加载。
    for (final installation in await manager.allInstallations()) {
      final manifest = installation.plugin.manifest;
      if (manifest == null) continue;
      final pluginId = installation.plugin.id;
      if (!(enabled[pluginId] ?? false)) {
        registry._disabled.add(pluginId);
        registry._inactive.add(installation);
        continue;
      }
      try {
        await registry._loadDynamic(installation, manifest);
      } on Object catch (error) {
        registry.issues.add('插件 $pluginId@${installation.version} 加载失败：$error');
      }
    }
    return registry;
  }

  /// 测试注入：不初始化动态运行时，只登记传入实例。
  factory PluginRegistry.forTesting({
    required StudioStore store,
    List<ProviderExtension> providers = const [],
    List<ImageProcessorExtension> processors = const [],
    List<ToolDescriptor> tools = const [],
  }) {
    final registry = PluginRegistry._(
      store,
      PluginManager(store),
      [],
      [],
      [],
      [],
    );
    for (final provider in providers) {
      registry._addProvider(provider);
    }
    for (final processor in processors) {
      registry._addProcessor(processor);
    }
    for (final tool in tools) {
      registry._addTool(tool);
    }
    return registry;
  }

  final StudioStore store;
  final PluginManager manager;
  final List<ProviderExtension> _providers;
  final List<ImageProcessorExtension> _processors;
  final List<ToolDescriptor> _tools;
  final List<PluginScript> _scripts;
  final Map<String, ProviderExtension> _active = {};

  /// 版本还在解析/按需编译时收到的取消，等真实 client 启动前拦下。
  final Set<String> _cancelPending = {};

  /// 已禁用的插件：不进新任务的可选项，pin 了版本的调用仍可解析。
  final Set<String> _disabled = {};

  /// 磁盘上保留但未编译的版本（禁用/已卸载），仅 pin 任务按需加载。
  final List<PluginInstallation> _inactive = [];

  /// 无法注册的扩展（ID 冲突、脚本加载失败）；不静默丢弃。
  final List<String> issues = [];

  List<ProviderDescriptor> get providers => [
    for (final entry in _activeProviders()) entry.descriptor,
  ];
  List<ProcessorDescriptor> get processors => [
    for (final entry in _activeProcessors()) entry.descriptor,
  ];

  /// 只暴露启用插件的当前工具版本。
  List<ToolDescriptor> get tools {
    final byOwner = <String, ToolDescriptor>{};
    for (final tool in _tools) {
      if (_disabled.contains(tool.pluginId)) continue;
      final key = '${tool.pluginId}\u0000${tool.id}';
      final current = byOwner[key];
      if (current == null ||
          _compareVersions(tool.version, current.version) > 0) {
        byOwner[key] = tool;
      }
    }
    return List.unmodifiable(byOwner.values);
  }

  void _addProvider(ProviderExtension provider) {
    final descriptor = provider.descriptor;
    final owners = {
      for (final item in _providers)
        if (item.descriptor.id == descriptor.id) item.descriptor.pluginId,
    };
    // 同一扩展 ID 只能由一个插件声明：别的插件不能靠版本号接管。
    if (owners.isNotEmpty && !owners.contains(descriptor.pluginId)) {
      issues.add(
        '适配器 ${descriptor.id} 已属于插件 ${owners.first}，拒绝插件 ${descriptor.pluginId}@${descriptor.version} 注册',
      );
      return;
    }
    if (_providers.any(
      (item) =>
          item.descriptor.id == descriptor.id &&
          item.descriptor.version == descriptor.version &&
          item.descriptor.pluginId == descriptor.pluginId,
    )) {
      issues.add('提供商扩展 ${descriptor.id}@${descriptor.version} 重复，已忽略后来注册的实例');
      return;
    }
    _providers.add(provider);
  }

  void _addProcessor(ImageProcessorExtension processor) {
    final descriptor = processor.descriptor;
    final owners = {
      for (final item in _processors)
        if (item.descriptor.id == descriptor.id) item.descriptor.pluginId,
    };
    if (owners.isNotEmpty && !owners.contains(descriptor.pluginId)) {
      issues.add(
        '处理器 ${descriptor.id} 已属于插件 ${owners.first}，拒绝插件 ${descriptor.pluginId}@${descriptor.version} 注册',
      );
      return;
    }
    if (_processors.any(
      (item) =>
          item.descriptor.id == descriptor.id &&
          item.descriptor.version == descriptor.version &&
          item.descriptor.pluginId == descriptor.pluginId,
    )) {
      issues.add('处理器扩展 ${descriptor.id}@${descriptor.version} 重复，已忽略后来注册的实例');
      return;
    }
    _processors.add(processor);
  }

  void _addTool(ToolDescriptor tool) {
    final owners = {
      for (final item in _tools)
        if (item.id == tool.id) item.pluginId,
    };
    if (owners.isNotEmpty && !owners.contains(tool.pluginId)) {
      issues.add(
        '工具 ${tool.id} 已属于插件 ${owners.first}，拒绝插件 ${tool.pluginId}@${tool.version} 注册',
      );
      return;
    }
    if (_tools.any(
      (item) =>
          item.id == tool.id &&
          item.version == tool.version &&
          item.pluginId == tool.pluginId,
    )) {
      return;
    }
    _tools.add(tool);
  }

  Future<void> _loadDynamic(
    PluginInstallation installation,
    PluginManifest manifest,
  ) async {
    final file = File(p.join(installation.directory.path, manifest.entry));
    if (!await file.exists()) {
      throw PluginException('入口文件 ${manifest.entry} 不存在');
    }
    final source = await file.readAsString();
    late final PluginScript script;
    try {
      script = PluginScript.compile(manifest: manifest, source: source);
    } on PluginScriptException catch (error) {
      throw PluginException(error.message);
    }
    _scripts.add(script);
    for (final spec in manifest.providers) {
      _addProvider(
        ScriptProviderExtension(
          descriptor: spec.descriptor(manifest.id, manifest.version),
          spec: spec,
          manifest: manifest,
          source: source,
          store: store,
        ),
      );
    }
    for (final spec in manifest.processors) {
      if (!manifest.permissions.image) {
        issues.add(
          '插件 ${manifest.id}@${manifest.version} 未申请图片权限，处理器 ${spec.id} 未加载',
        );
        continue;
      }
      _addProcessor(
        PluginScriptProcessor(
          descriptor: spec.descriptor(manifest.id, manifest.version),
          function: spec.processFunction,
          script: script,
        ),
      );
    }
    for (final spec in manifest.tools) {
      if (!_hasProcessor(manifest.id, manifest.version, spec.processorId)) {
        issues.add(
          '插件 ${manifest.id}@${manifest.version} 的工具 ${spec.id} 依赖的处理器未加载',
        );
        continue;
      }
      _addTool(spec.descriptor(manifest.id, manifest.version));
    }
  }

  bool _hasProcessor(String pluginId, String version, String processorId) =>
      _processors.any(
        (item) =>
            item.descriptor.pluginId == pluginId &&
            item.descriptor.version == version &&
            item.descriptor.id == processorId,
      );

  /// 同 ID 多版本并存时，未 pin 的调用使用启用插件里的最高版本（内置版本为 1.0.0）。
  List<ProviderExtension> _activeProviders() {
    final byOwner = <String, ProviderExtension>{};
    for (final provider in _providers) {
      final descriptor = provider.descriptor;
      if (_disabled.contains(descriptor.pluginId)) continue;
      final key = '${descriptor.pluginId}\u0000${descriptor.id}';
      final current = byOwner[key];
      if (current == null ||
          _compareVersions(descriptor.version, current.descriptor.version) >
              0) {
        byOwner[key] = provider;
      }
    }
    return byOwner.values.toList();
  }

  List<ImageProcessorExtension> _activeProcessors() {
    final byOwner = <String, ImageProcessorExtension>{};
    for (final processor in _processors) {
      final descriptor = processor.descriptor;
      if (_disabled.contains(descriptor.pluginId)) continue;
      final key = '${descriptor.pluginId}\u0000${descriptor.id}';
      final current = byOwner[key];
      if (current == null ||
          _compareVersions(descriptor.version, current.descriptor.version) >
              0) {
        byOwner[key] = processor;
      }
    }
    return byOwner.values.toList();
  }

  static int _compareVersions(String left, String right) {
    final a = left.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    final b = right.split('.').map((part) => int.tryParse(part) ?? 0).toList();
    for (var i = 0; i < 3; i++) {
      final diff = (a.elementAtOrNull(i) ?? 0).compareTo(
        b.elementAtOrNull(i) ?? 0,
      );
      if (diff != 0) return diff;
    }
    return 0;
  }

  /// 严格按 adapterId 查找；pin 了版本就必须命中该版本，不换版兜底。
  ProviderExtension? _resolveProvider(String adapterId, String? version) {
    final candidates = [
      for (final item in _providers)
        if (item.descriptor.id == adapterId &&
            (version != null || !_disabled.contains(item.descriptor.pluginId)))
          item,
    ];
    if (candidates.isEmpty) return null;
    final owners = {for (final item in candidates) item.descriptor.pluginId};
    if (owners.length > 1) return null;
    if (version != null) {
      for (final item in candidates) {
        if (item.descriptor.version == version) return item;
      }
      return null;
    }
    candidates.sort(
      (a, b) => _compareVersions(b.descriptor.version, a.descriptor.version),
    );
    return candidates.first;
  }

  /// pin 到未编译的旧版本时，只为它编译一次。
  Future<ProviderExtension?> _ensureProvider(
    String adapterId,
    String? version,
  ) async {
    final found = _resolveProvider(adapterId, version);
    if (found != null || version == null) return found;
    await _activateInactive(
      (installation, manifest) =>
          installation.version == version &&
          manifest.providers.any((spec) => spec.id == adapterId),
    );
    return _resolveProvider(adapterId, version);
  }

  /// pin 到未编译的旧版本时，只为请求的那一个版本、那一个扩展编译。
  Future<void> _activateInactive(
    bool Function(PluginInstallation installation, PluginManifest manifest)
    matches,
  ) async {
    for (final installation in List.of(_inactive)) {
      final manifest = installation.plugin.manifest;
      if (manifest == null) continue;
      if (!matches(installation, manifest)) continue;
      _inactive.remove(installation);
      try {
        await _loadDynamic(installation, manifest);
      } on Object catch (error) {
        issues.add('插件 ${manifest.id}@${manifest.version} 按需加载失败：$error');
      }
    }
  }

  String _disabledReason(String pluginId) =>
      '插件「$pluginId」已禁用，不能提交新任务；如需继续使用请先启用该插件';

  String _missingReason(String adapterId, String? version) {
    final installed = _providers
        .where((item) => item.descriptor.id == adapterId)
        .toList();
    if (installed.isEmpty) return '未安装插件适配器「$adapterId」，不能生成，请先安装该插件';
    final owners = {for (final item in installed) item.descriptor.pluginId};
    if (owners.length > 1) {
      return '插件适配器「$adapterId」被多个插件声明（${owners.join('、')}），不能确定实现，请卸载冲突插件';
    }
    if (version != null) {
      final versions = installed
          .map((item) => item.descriptor.version)
          .toList();
      return '插件适配器「$adapterId」缺少版本 $version（已安装：${versions.join('、')}），不会自动换版';
    }
    final plugins = installed
        .map((item) => item.descriptor.pluginId)
        .toSet()
        .join('、');
    return '插件适配器「$adapterId」所属插件（$plugins）已禁用，不能生成；如需继续使用请先启用该插件';
  }

  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  }) {
    final extension = _resolveProvider(
      provider.adapterId,
      provider.adapterVersion,
    );
    if (extension == null) return const GenerationCapabilities();
    return extension.capabilities(provider, hasInputImages: hasInputImages);
  }

  Future<List<String>> discoverModels(
    ProviderConfig provider,
    String? apiKey,
  ) async {
    final extension = await _ensureProvider(
      provider.adapterId,
      provider.adapterVersion,
    );
    if (extension == null) {
      throw PluginException(
        _missingReason(provider.adapterId, provider.adapterVersion),
      );
    }
    return extension.discoverModels(provider, apiKey);
  }

  Future<GenerationPlan> plan(GenerationInput input) async {
    final extension = await _ensureProvider(
      input.provider.adapterId,
      input.provider.adapterVersion,
    );
    if (extension == null) {
      throw PluginException(
        _missingReason(input.provider.adapterId, input.provider.adapterVersion),
      );
    }
    return extension.plan(input);
  }

  /// 固定供应商与处理步骤的插件版本，任务快照不再随插件更新漂移。
  Future<GenerationInput> pinInput(GenerationInput input) async {
    final extension = await _ensureProvider(
      input.provider.adapterId,
      input.provider.adapterVersion,
    );
    if (extension == null) {
      throw PluginException(
        _missingReason(input.provider.adapterId, input.provider.adapterVersion),
      );
    }
    // 新提交门口：pin 住的旧版本可执行，但插件被禁用后不再接受新任务。
    if (_disabled.contains(extension.descriptor.pluginId)) {
      throw PluginException(_disabledReason(extension.descriptor.pluginId));
    }
    final provider = input.provider.adapterVersion == null
        ? input.provider.copyWith(adapterVersion: extension.descriptor.version)
        : input.provider;
    final preprocessors = [
      for (final step in input.preprocessors) await _pinStep(step),
    ];
    final postprocessors = [
      for (final step in input.postprocessors) await _pinStep(step),
    ];
    return input.copyWith(
      provider: provider,
      preprocessors: preprocessors,
      postprocessors: postprocessors,
    );
  }

  Future<ProcessingStep> _pinStep(ProcessingStep step) async {
    final resolved = await _ensureProcessor(step);
    if (_disabled.contains(resolved.descriptor.pluginId)) {
      throw PluginException(_disabledReason(resolved.descriptor.pluginId));
    }
    return resolved.descriptor.version == step.version
        ? step
        : ProcessingStep(
            pluginId: step.pluginId,
            version: resolved.descriptor.version,
            processorId: step.processorId,
            params: step.params,
          );
  }

  ImageProcessorExtension processor(ProcessingStep step) {
    final candidates = [
      for (final item in _processors)
        if (item.descriptor.id == step.processorId &&
            (step.pluginId.isEmpty ||
                item.descriptor.pluginId == step.pluginId) &&
            (step.version.isNotEmpty ||
                !_disabled.contains(item.descriptor.pluginId)))
          item,
    ];
    if (candidates.isEmpty) {
      throw PluginException(
        '找不到处理器「${step.processorId}」（插件 ${step.pluginId.isEmpty ? '未知' : step.pluginId}），请检查插件是否已安装或启用',
      );
    }
    if (step.version.isNotEmpty) {
      for (final item in candidates) {
        if (item.descriptor.version == step.version) return item;
      }
      final versions = candidates
          .map((item) => item.descriptor.version)
          .toSet()
          .join('、');
      throw PluginException(
        '插件 ${step.pluginId} 缺少版本 ${step.version} 的处理器 ${step.processorId}（已安装：$versions），不会自动换版',
      );
    }
    candidates.sort(
      (a, b) => _compareVersions(b.descriptor.version, a.descriptor.version),
    );
    return candidates.first;
  }

  /// pin 到未编译的旧版本时，只为它编译一次。
  Future<ImageProcessorExtension> _ensureProcessor(ProcessingStep step) async {
    try {
      return processor(step);
    } on PluginException {
      if (step.version.isEmpty) rethrow;
      await _activateInactive(
        (installation, manifest) =>
            installation.version == step.version &&
            (step.pluginId.isEmpty || manifest.id == step.pluginId) &&
            manifest.processors.any((spec) => spec.id == step.processorId),
      );
      return processor(step);
    }
  }

  /// 处理器只能读本次创建的资产：按 id 取规范对象读文件，绝不使用调用方给的路径。
  Future<ImageAsset> process(
    ImageAsset image,
    ProcessingStep step, {
    bool Function()? isCancelled,
  }) async {
    final extension = await _ensureProcessor(step);
    final allowed = <String, ImageAsset>{image.id: image};
    bool cancelled() => isCancelled?.call() ?? false;
    final context = ProcessingContext(
      readImage: (asset) async {
        final canonical = allowed[asset.id];
        if (canonical == null) {
          throw const PluginException('处理器只能读取本次创建的图片');
        }
        if (cancelled()) throw const ProcessingCancelled();
        return store.readAsset(canonical);
      },
      saveImage: (bytes, mime) async {
        if (cancelled()) throw const ProcessingCancelled();
        final saved = await store.saveAsset(bytes, mime);
        allowed[saved.id] = saved;
        return saved;
      },
      isCancelled: isCancelled,
    );
    return extension.process(image, step.params, context);
  }

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) {
    // 新尝试在调用时就重置取消标记；之后到达的取消保留到 client 启动前检查。
    _cancelPending.remove(input.taskId);
    return _runGenerate(input, apiKey);
  }

  Stream<GenerationEvent> _runGenerate(
    GenerationInput input,
    String apiKey,
  ) async* {
    final extension = await _ensureProvider(
      input.provider.adapterId,
      input.provider.adapterVersion,
    );
    if (extension == null) {
      throw PluginException(
        _missingReason(input.provider.adapterId, input.provider.adapterVersion),
      );
    }
    if (_cancelPending.remove(input.taskId)) {
      // 解析版本/按需编译期间已被取消：不启动 client，也就不发付费请求。
      return;
    }
    // 记录实际 client，取消时直接命中它，不新建实例。
    _active[input.taskId] = extension;
    try {
      yield* extension.generate(input, apiKey);
    } finally {
      if (identical(_active[input.taskId], extension)) {
        _active.remove(input.taskId);
      }
    }
  }

  @override
  void cancel(String taskId) {
    final extension = _active.remove(taskId);
    if (extension != null) {
      extension.cancel(taskId);
      return;
    }
    // 还在解析版本/按需编译：留给 generate 在启动 client 前拦下。
    _cancelPending.add(taskId);
  }

  /// 释放动态脚本运行时；调用后注册表不再可用。
  Future<void> dispose() async {
    _active.clear();
    _cancelPending.clear();
    for (final script in _scripts) {
      script.dispose();
    }
    _scripts.clear();
    _inactive.clear();
    _disabled.clear();
    _providers.clear();
    _processors.clear();
    _tools.clear();
  }
}
