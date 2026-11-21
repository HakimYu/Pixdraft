import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/plugin_contract.dart';
import '../../plugins/plugin_registry.dart';
import 'provider_connection.dart';
import 'provider_editor_page.dart';
import 'provider_detail_page.dart';

class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key, required this.store, this.registry});

  final StudioStore store;

  /// 传入已加载的注册表可复用其实例；为空时页面自行加载并在销毁时释放。
  final PluginRegistry? registry;

  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  final ProviderModelChecker _checker = ProviderModelChecker();
  PluginRegistry? _registry;
  bool _ownsRegistry = false;
  List<ProviderConfig>? _providers;
  String? _selectedId;
  Object? _loadError;
  bool _loading = true;
  final Map<String, ModelCheckResult> _checks = {};
  final Set<String> _checking = {};

  @override
  void initState() {
    super.initState();
    _registry = widget.registry;
    if (_registry == null) unawaited(_loadRegistry());
    _load();
  }

  /// 插件索引不可用时退回旧标签，不阻断供应商管理。
  Future<void> _loadRegistry() async {
    try {
      final registry = await PluginRegistry.load(widget.store);
      if (!mounted) {
        await registry.dispose();
        return;
      }
      setState(() {
        _registry = registry;
        _ownsRegistry = true;
      });
    } catch (_) {
      // 保持 _registry 为空。
    }
  }

  @override
  void dispose() {
    _checker.close();
    if (_ownsRegistry) unawaited(_registry?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final providers = await widget.store.providers();
      final selection = await widget.store.setting('selection');
      final selectedId = selection?['providerId'];
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _selectedId = selectedId is String ? selectedId : null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _describe(Object error) =>
      error is FormatException ? error.message : '$error';

  Future<void> _openEditor([ProviderConfig? provider]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => provider == null
            ? ProviderEditorPage(store: widget.store, registry: _registry)
            : ProviderDetailPage(
                store: widget.store,
                provider: provider,
                registry: _registry,
              ),
      ),
    );
    if (saved == true || provider != null) {
      if (!mounted) return;
      if (provider != null) _checks.remove(provider.id);
      await _load();
      if (saved == true) _showMessage('已新增供应商');
    }
  }

  Future<void> _setEnabled(ProviderConfig provider, bool enabled) async {
    final updated = ProviderConfig.fromJson({
      ...provider.toJson(),
      'enabled': enabled,
    });
    try {
      await widget.store.saveProvider(updated);
      if (!mounted) return;
      setState(() {
        _providers = [
          for (final item in _providers ?? <ProviderConfig>[])
            item.id == updated.id ? updated : item,
        ];
      });
    } catch (error) {
      if (mounted) setState(() {});
      _showMessage('保存失败：${_describe(error)}');
    }
  }

  Future<void> _setDefault(ProviderConfig provider) async {
    try {
      await widget.store.saveSetting('selection', {'providerId': provider.id});
      if (!mounted) return;
      setState(() => _selectedId = provider.id);
      _showMessage('已将「${provider.name}」设为默认供应商');
    } catch (error) {
      _showMessage('设置默认供应商失败：${_describe(error)}');
    }
  }

  Future<void> _duplicate(ProviderConfig provider) async {
    final copy = ProviderConfig.fromJson({
      ...provider.toJson(),
      'id': newId(),
      'name': '${provider.name} 副本',
    });
    try {
      await widget.store.saveProvider(copy);
      if (!mounted) return;
      await _load();
      _showMessage('已复制供应商，请重新填写密钥');
    } catch (error) {
      _showMessage('复制失败：${_describe(error)}');
    }
  }

  Future<void> _delete(ProviderConfig provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除供应商？'),
        content: Text('将删除「${provider.name}」及其保存的密钥。历史任务不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirmDeleteProvider'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.store.deleteProvider(provider.id);
      if (_selectedId == provider.id) {
        await _selectFallbackAfterDelete(provider.id);
      }
      if (!mounted) return;
      await _load();
      _showMessage('已删除供应商');
    } catch (error) {
      _showMessage('删除失败：${_describe(error)}');
    }
  }

  Future<void> _selectFallbackAfterDelete(String deletedId) async {
    final remaining = [
      for (final provider in _providers ?? <ProviderConfig>[])
        if (provider.id != deletedId) provider,
    ];
    ProviderConfig? fallback;
    for (final provider in remaining) {
      if (provider.enabled) {
        fallback = provider;
        break;
      }
    }
    fallback ??= remaining.isEmpty ? null : remaining.first;
    try {
      await widget.store.saveSetting('selection', {'providerId': fallback?.id});
    } catch (error) {
      _showMessage('更新默认供应商失败：${_describe(error)}');
    }
  }

  static const _legacyAdapterIds = {
    'images',
    'responses',
    'wavespeed',
    'evolink',
  };

  /// 与后台 LegacyClient 边界一致：只有未固定版本的旧内置配置才允许旧检查器。
  bool _isLegacyConfig(ProviderConfig provider) =>
      _legacyAdapterIds.contains(provider.adapterId) &&
      provider.adapterVersion == null;

  /// 检查连接是用户新发起的操作：缺失、停用的适配器直接拒绝，不沿用固定版本执行豁免。
  Future<void> _check(ProviderConfig provider) async {
    final registry = _registry;
    if (registry == null
        ? !_isLegacyConfig(provider)
        : _descriptorFor(provider) == null) {
      _showMessage('适配器「${provider.adapterId}」未安装或未启用，无法检查连接；请先安装并启用对应插件。');
      return;
    }
    setState(() {
      _checking.add(provider.id);
      _checks.remove(provider.id);
    });
    try {
      final key = await widget.store.apiKey(provider.id, baseUrl: provider.baseUrl);
      final result = registry == null
          ? await _checker.check(provider, key)
          : await _checkRegistered(registry, provider, key);
      if (!mounted) return;
      setState(() => _checks[provider.id] = result);
    } catch (error) {
      _showMessage('检查连接失败：${_describe(error)}');
    } finally {
      if (mounted) setState(() => _checking.remove(provider.id));
    }
  }

  /// 注册表就绪时经实际 extension 发现模型，避免把密钥发到插件未声明的主机。
  Future<ModelCheckResult> _checkRegistered(
    PluginRegistry registry,
    ProviderConfig provider,
    String? key,
  ) async {
    try {
      final models = await registry.discoverModels(provider, key);
      if (models.isEmpty) {
        return const ModelCheckResult(
          ModelCheckStatus.noModelEndpoint,
          '该服务未提供 /models 接口（或未返回模型），请手动添加模型；这不代表生图不可用。',
        );
      }
      return ModelCheckResult(
        ModelCheckStatus.ok,
        '连接正常，共 ${models.length} 个模型；仅查询了模型列表，未发起生图请求。',
        models: models,
      );
    } on FormatException catch (error) {
      return ModelCheckResult(ModelCheckStatus.failed, error.message);
    }
  }

  /// 按 adapterId 找到实际安装的插件描述；未安装时返回 null（卡片给出提示）。
  ProviderDescriptor? _descriptorFor(ProviderConfig provider) {
    final registry = _registry;
    if (registry == null) return null;
    for (final descriptor in registry.providers) {
      if (descriptor.id == provider.adapterId) return descriptor;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('供应商')),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('addProvider'),
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('新增供应商'),
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _providers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return _ErrorView(error: _loadError!, onRetry: _load);
    }
    final providers = _providers ?? const <ProviderConfig>[];
    if (providers.isEmpty) return _EmptyView(onAdd: () => _openEditor());
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      itemCount: providers.length,
      itemBuilder: (context, index) {
        final provider = providers[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _ProviderCard(
            provider: provider,
            descriptor: _descriptorFor(provider),
            registryReady: _registry != null,
            isDefault: provider.id == _selectedId,
            checking: _checking.contains(provider.id),
            result: _checks[provider.id],
            onEdit: () => _openEditor(provider),
            onToggle: (enabled) => _setEnabled(provider, enabled),
            onSetDefault: () => _setDefault(provider),
            onDuplicate: () => _duplicate(provider),
            onDelete: () => _delete(provider),
            onCheck: () => _check(provider),
          ),
        );
      },
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.descriptor,
    required this.registryReady,
    required this.isDefault,
    required this.checking,
    required this.result,
    required this.onEdit,
    required this.onToggle,
    required this.onSetDefault,
    required this.onDuplicate,
    required this.onDelete,
    required this.onCheck,
  });

  final ProviderConfig provider;
  final ProviderDescriptor? descriptor;
  final bool registryReady;
  final bool isDefault;
  final bool checking;
  final ModelCheckResult? result;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetDefault;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = Uri.tryParse(provider.baseUrl)?.host ?? provider.baseUrl;
    final modelSummary = provider.protocol != ApiProtocol.responses
        ? '图像模型 ${provider.imageModel}'
        : '主模型 ${provider.responseModel} · 工具图像模型 ${provider.toolModel}';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(provider.name, style: theme.textTheme.titleMedium),
                      Text(
                        host,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: ValueKey('enabled-${provider.id}'),
                  value: provider.enabled,
                  onChanged: onToggle,
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (isDefault)
                  const Chip(
                    avatar: Icon(Icons.check_circle, size: 18),
                    label: Text('默认'),
                  ),
                if (!provider.enabled) const Chip(label: Text('已停用')),
                if (descriptor != null)
                  Chip(label: Text(descriptor!.name))
                else if (registryReady)
                  Chip(
                    key: ValueKey('missing-adapter-${provider.id}'),
                    backgroundColor: theme.colorScheme.errorContainer,
                    label: Text('插件未安装：${provider.adapterId}'),
                  )
                else
                  Chip(label: Text(provider.protocol.label)),
                Chip(label: Text(_transportLabel(provider.transport))),
              ],
            ),
            const SizedBox(height: 8),
            Text(modelSummary, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            if (result != null) _CheckResultLine(result: result!),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _action(
                  key: ValueKey('check-${provider.id}'),
                  onPressed: checking ? null : onCheck,
                  icon: checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check),
                  label: checking ? '检查中…' : '检查连接',
                ),
                if (!isDefault)
                  _action(
                    key: ValueKey('default-${provider.id}'),
                    onPressed: onSetDefault,
                    icon: const Icon(Icons.radio_button_unchecked),
                    label: '设为默认',
                  ),
                _action(
                  key: ValueKey('edit-${provider.id}'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: '管理',
                ),
                _action(
                  key: ValueKey('duplicate-${provider.id}'),
                  onPressed: onDuplicate,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: '复制',
                ),
                _action(
                  key: ValueKey('delete-${provider.id}'),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: '删除',
                  color: theme.colorScheme.error,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _transportLabel(TransportMode transport) => switch (transport) {
    TransportMode.auto => '自动传输',
    TransportMode.stream => '流式传输',
    TransportMode.json => 'JSON 传输',
  };

  Widget _action({
    required Key key,
    required VoidCallback? onPressed,
    required Widget icon,
    required String label,
    Color? color,
  }) {
    return TextButton.icon(
      key: key,
      onPressed: onPressed,
      icon: icon,
      label: Text(label),
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: color,
      ),
    );
  }
}

class _CheckResultLine extends StatelessWidget {
  const _CheckResultLine({required this.result});

  final ModelCheckResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (result.status) {
      ModelCheckStatus.ok => (
        Icons.check_circle_outline,
        theme.colorScheme.primary,
      ),
      ModelCheckStatus.unauthorized => (
        Icons.key_off_outlined,
        theme.colorScheme.error,
      ),
      _ => (Icons.info_outline, theme.colorScheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              result.message,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hub_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '还没有供应商',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '支持 OpenAI Images、Responses、WaveSpeed 和 EvoLink，填写地址和密钥后即可开始创作。',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('新增供应商'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              '无法读取供应商列表，请重试。',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('providersRetry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ],
        ),
      ),
    );
  }
}
