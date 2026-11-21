import 'package:flutter/material.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/plugin_registry.dart';
import 'provider_connection.dart';
import 'provider_editor_page.dart';

class ProviderDetailPage extends StatefulWidget {
  const ProviderDetailPage({
    super.key,
    required this.store,
    required this.provider,
    this.checker,
    this.registry,
    this.showModels = false,
  });
  final StudioStore store;
  final ProviderConfig provider;
  final ProviderModelChecker? checker;

  /// 已安装插件注册表；存在时模型发现走实际 extension。
  final PluginRegistry? registry;
  final bool showModels;

  @override
  State<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<ProviderDetailPage> {
  late ProviderConfig _provider;
  late final ProviderModelChecker _checker;
  final _manualModel = TextEditingController();
  late final List<String> _models;
  String _query = '';
  String? _message;
  bool _fetching = false, _saving = false;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider;
    _models = List.of(_provider.enabledModels);
    _checker = widget.checker ?? ProviderModelChecker();
  }

  @override
  void dispose() {
    _manualModel.dispose();
    if (widget.checker == null) _checker.close();
    super.dispose();
  }

  static const _legacyAdapterIds = {
    'images',
    'responses',
    'wavespeed',
    'evolink',
  };

  /// 与后台 LegacyClient 边界一致：只有未固定版本的旧内置配置才允许旧检查器。
  bool get _isLegacyConfig =>
      _legacyAdapterIds.contains(_provider.adapterId) &&
      _provider.adapterVersion == null;

  bool _hasAdapter(PluginRegistry registry) => registry.providers.any(
    (descriptor) => descriptor.id == _provider.adapterId,
  );

  Future<void> _fetch() async {
    final registry = widget.registry;
    // 手动发现模型是新操作：缺失、停用的适配器先拒绝，不能退回旧检查器。
    if (registry == null ? !_isLegacyConfig : !_hasAdapter(registry)) {
      setState(() {
        _message = '适配器「${_provider.adapterId}」未安装或未启用，无法检查模型；请先安装并启用对应插件。';
      });
      return;
    }
    setState(() {
      _fetching = true;
      _message = null;
    });
    final key = await widget.store.apiKey(_provider.id, baseUrl: _provider.baseUrl);
    try {
      final List<String> discovered;
      String message;
      if (registry != null) {
        discovered = await registry.discoverModels(_provider, key);
        message = discovered.isEmpty
            ? '该服务未提供 /models 接口（或未返回模型），请手动添加模型；这不代表生图不可用。'
            : '已获取 ${discovered.length} 个模型；仅查询了模型列表，未发起生图请求。';
      } else {
        final result = await _checker.check(_provider, key);
        if (result.status != ModelCheckStatus.ok) {
          if (!mounted) return;
          setState(() => _message = result.message);
          return;
        }
        discovered = result.models;
        message = result.message;
      }
      if (!mounted) return;
      setState(() {
        final fetched =
            discovered
                .map((id) => id.trim())
                .where((id) => id.isNotEmpty)
                .toSet()
                .toList()
              ..sort();
        _models.addAll(fetched.where((id) => !_models.contains(id)));
        _message = message;
      });
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (_) {
      if (mounted) setState(() => _message = '获取模型失败，请检查连接后重试');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _save(Map<String, dynamic> changes) async {
    if (_saving) return;
    final updated = ProviderConfig.fromJson({
      ..._provider.toJson(),
      ...changes,
    });
    setState(() => _saving = true);
    try {
      await widget.store.saveProvider(updated);
      if (mounted) {
        setState(() {
          _provider = updated;
          _models.addAll(
            updated.enabledModels.where((id) => !_models.contains(id)),
          );
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggle(String id) async {
    final models = List<String>.of(_provider.enabledModels);
    if (models.contains(id)) {
      models.remove(id);
    } else {
      models.add(id);
    }
    // 移除默认项时改用剩余第一项；空列表保留配置但禁止新生成。
    await _save({
      'models': models,
      if (models.isNotEmpty)
        for (final entry in {
          'imageModel': _provider.imageModel,
          'responseModel': _provider.responseModel,
          'toolModel': _provider.toolModel,
        }.entries)
          if (!models.contains(entry.value)) entry.key: models.first,
    });
  }

  Future<void> _add() async {
    final controller = _manualModel..clear();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动添加模型'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '模型 ID'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (id == null || !mounted || _provider.enabledModels.contains(id)) return;
    await _toggle(id);
  }

  Future<bool> _edit() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProviderEditorPage(
          store: widget.store,
          provider: _provider,
          registry: widget.registry,
        ),
      ),
    );
    if (saved != true || !mounted) return false;
    try {
      final providers = await widget.store.providers();
      if (!mounted) return false;
      final updated = providers.where((p) => p.id == _provider.id).first;
      setState(() {
        if (updated.baseUrl != _provider.baseUrl) {
          _models.removeWhere((id) => !updated.enabledModels.contains(id));
          _message = null;
        }
        _provider = updated;
        _models.addAll(
          updated.enabledModels.where((id) => !_models.contains(id)),
        );
      });
      return true;
    } catch (_) {
      if (mounted) setState(() => _message = '读取供应商失败，请返回后重试');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = _models
        .where((id) => id.toLowerCase().contains(_query.trim().toLowerCase()))
        .toList();
    final roles = _provider.protocol != ApiProtocol.responses
        ? {'imageModel': ('图像默认模型', _provider.imageModel)}
        : {
            'responseModel': ('Responses 主模型', _provider.responseModel),
            'toolModel': ('Responses 工具图像模型', _provider.toolModel),
          };
    return DefaultTabController(
      length: 2,
      initialIndex: widget.showModels ? 1 : 0,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(_provider.name),
            bottom: const TabBar(
              tabs: [
                Tab(text: '配置'),
                Tab(text: '模型'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ListTile(
                    title: const Text('连接配置'),
                    subtitle: Text(
                      '${_provider.baseUrl}\n${_provider.protocol.name}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _saving || _fetching
                        ? null
                        : () async {
                            if (await _edit() && context.mounted) {
                              DefaultTabController.of(context).animateTo(1);
                            }
                          },
                  ),
                  ListTile(
                    title: const Text('已启用模型'),
                    subtitle: Text(
                      '${_provider.enabledModels.length} 个；在模型页管理',
                    ),
                  ),
                ],
              ),
              CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _fetching || _saving ? null : _fetch,
                                icon: const Icon(Icons.sync),
                                label: Text(_fetching ? '获取中…' : '获取模型'),
                              ),
                              TextButton.icon(
                                onPressed: _saving ? null : _add,
                                icon: const Icon(Icons.add),
                                label: const Text('手动添加'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '加号启用，减号移除。模型列表不能判断图像能力，请按供应商说明选择。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                          const SizedBox(height: 20),
                          for (final role in roles.entries)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                  '${role.key}:${role.value.$2}:${_provider.enabledModels.join(',')}',
                                ),
                                initialValue:
                                    _provider.enabledModels.contains(
                                      role.value.$2,
                                    )
                                    ? role.value.$2
                                    : null,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: role.value.$1,
                                ),
                                items: _provider.enabledModels
                                    .map(
                                      (id) => DropdownMenuItem(
                                        value: id,
                                        child: Text(
                                          id,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _saving
                                    ? null
                                    : (id) {
                                        if (id != null) _save({role.key: id});
                                      },
                              ),
                            ),
                          TextField(
                            decoration: const InputDecoration(
                              labelText: '搜索模型',
                              prefixIcon: Icon(Icons.search),
                            ),
                            onChanged: (value) =>
                                setState(() => _query = value),
                          ),
                          if (_message != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_message!),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (models.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('没有匹配模型，可获取列表或手动添加'),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: models.length,
                      itemBuilder: (context, index) {
                        final id = models[index];
                        final enabled = _provider.enabledModels.contains(id);
                        return ListTile(
                          title: Text(id),
                          subtitle: Text(enabled ? '已启用' : '未启用'),
                          trailing: IconButton(
                            tooltip: '${enabled ? '移除' : '启用'} $id',
                            onPressed: _saving ? null : () => _toggle(id),
                            icon: Icon(
                              enabled
                                  ? Icons.remove_circle_outline
                                  : Icons.add_circle_outline,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
