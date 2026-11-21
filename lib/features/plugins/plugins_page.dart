import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../data/studio_store.dart';
import '../../plugins/plugin_manifest.dart';
import '../../plugins/plugin_manager.dart';

const maxPluginArchiveBytes = 16 * 1024 * 1024;

class PluginsPage extends StatefulWidget {
  const PluginsPage({
    super.key,
    required this.store,
    this.manager,
    this.pickArchive,
  });
  final StudioStore store;
  final PluginManager? manager;
  final Future<Uint8List?> Function()? pickArchive;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  PluginManager? _manager;
  List<InstalledPlugin> _plugins = [];
  bool _loading = true, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final manager = widget.manager ?? PluginManager(widget.store);
      final plugins = await manager.list();
      if (!mounted) return;
      setState(() {
        _manager = manager;
        _plugins = plugins;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取插件列表失败，请重试';
      });
    }
  }

  String _message(Object error, String fallback) => switch (error) {
    PluginException(:final message) ||
    FormatException(:final message) => message,
    _ => fallback,
  };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _import() async {
    if (_busy) return;
    final manager = _manager;
    if (manager == null) return _toast('插件管理器还没有就绪');
    Uint8List? bytes;
    try {
      bytes = await (widget.pickArchive ?? _pickZip)();
    } catch (error) {
      return _toast(_message(error, '无法读取所选 ZIP 文件'));
    }
    if (!mounted) return;
    if (bytes == null) return;
    if (bytes.isEmpty) return _toast('ZIP 文件为空');
    if (bytes.length > maxPluginArchiveBytes)
      return _toast('插件 ZIP 不能超过 16 MB');
    final PluginManifest manifest;
    try {
      manifest = await manager.inspect(bytes);
    } catch (error) {
      return _toast(_message(error, '不是有效的插件包，请检查 ZIP 内容'));
    }
    if (!mounted) return;
    final existing = _plugins
        .where((plugin) => plugin.id == manifest.id)
        .firstOrNull;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          existing == null
              ? '安装 ${manifest.name} ${manifest.version}？'
              : '把 ${manifest.name} 更新到 ${manifest.version}？',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '插件 ID：${manifest.id}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              ..._manifestSummary(manifest),
              const SizedBox(height: 12),
              const Text('只从可信来源安装。图像的本地处理不联网，处理过程不会上传图片。'),
              if (existing != null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('更新只影响之后的任务，已排队的任务继续使用旧版本。'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(existing == null ? '安装' : '更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final installed = await manager.install(bytes);
      await _load();
      _toast('${installed.name} ${installed.version} 已安装，尚未启用');
    } catch (error) {
      _toast(_message(error, '插件安装失败，请检查 ZIP 内容'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 安装或启用前展示 ZIP 里真实的声明：提供什么能力、会访问哪些域名。
  List<Widget> _manifestSummary(PluginManifest manifest) => [
    Text('提供的能力', style: Theme.of(context).textTheme.titleSmall),
    if (manifest.providers.isNotEmpty)
      Text(
        '· 生图服务 ${manifest.providers.length} 个（${manifest.providers.map((provider) => provider.name).join('、')}）',
      ),
    if (manifest.processors.isNotEmpty)
      Text(
        '· 图片处理器 ${manifest.processors.length} 个（${manifest.processors.map((processor) => processor.name).join('、')}）',
      ),
    if (manifest.tools.isNotEmpty)
      Text(
        '· 工具 ${manifest.tools.length} 个（${manifest.tools.map((tool) => tool.name).join('、')}）',
      ),
    const SizedBox(height: 12),
    Text('网络访问', style: Theme.of(context).textTheme.titleSmall),
    Text(
      manifest.permissions.credentials.isEmpty
          ? '· 未声明域名，只在本机运行'
          : '· 仅向 ${manifest.permissions.credentials.join('、')} 发起请求',
    ),
  ];

  /// 启用即允许插件代码运行，先给出它声明的权限再确认。
  Future<bool> _confirmEnable(InstalledPlugin plugin) async {
    final manifest = plugin.manifest;
    if (manifest == null) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('启用 ${plugin.name}？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._manifestSummary(manifest),
              const SizedBox(height: 12),
              const Text('启用后插件代码才会运行；不确定来源时请保持关闭或卸载。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('启用'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<Uint8List?> _pickZip() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: '选择插件 ZIP',
    );
    final file = files.singleOrNull;
    if (file == null) return null;
    final length = await file.length();
    if (length != null && length > maxPluginArchiveBytes)
      throw const FormatException('插件 ZIP 不能超过 16 MB');
    return file.xFile.readAsBytes();
  }

  String _builtinDescription(InstalledPlugin plugin) => switch (plugin.id) {
    'builtin.providers' => '随应用提供 OpenAI Images、OpenAI Responses、WaveSpeed 和 EvoLink 四种生图协议适配器；供应商账号与模型在供应商页面分别配置。',
    'builtin.local-tools' => '提供缩放和水印工具，可手动处理图片或加入创作前后处理；图片仅在本机处理，原图不会被覆盖。',
    _ => plugin.id,
  };

  Future<void> _toggle(InstalledPlugin plugin, bool enabled) async {
    final manager = _manager;
    if (manager == null || _busy) return;
    if (enabled && !await _confirmEnable(plugin)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await manager.setEnabled(plugin.id, enabled);
      await _load();
      _toast(enabled ? '已启用 ${plugin.name}' : '已停用 ${plugin.name}');
    } catch (error) {
      _toast(_message(error, '切换插件状态失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall(InstalledPlugin plugin) async {
    final manager = _manager;
    if (manager == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载 ${plugin.name}？'),
        content: const Text('卸载后它提供的处理器与工具将不可用，已生成的作品不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await manager.uninstall(plugin.id);
      await _load();
      _toast('已卸载 ${plugin.name}');
    } catch (error) {
      _toast(_message(error, '卸载插件失败'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('插件')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) ...[
          const LinearProgressIndicator(),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          onPressed: _busy ? null : _import,
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('导入插件 ZIP'),
        ),
        const SizedBox(height: 8),
        Text(
          '导入新版本 ZIP 会更新已安装的同名插件；安装后需手动启用。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.error_outline),
              title: Text(_error!),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          )
        else if (_plugins.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('还没有安装插件，导入 ZIP 即可添加能力')),
          )
        else
          for (final plugin in _plugins)
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                title: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(plugin.name),
                    Text(
                      'v${plugin.version}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (plugin.builtIn)
                      const Chip(
                        label: Text('内置'),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(plugin.id),
                    if (plugin.builtIn) Text(_builtinDescription(plugin)),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: plugin.enabled,
                      onChanged: _busy
                          ? null
                          : (value) => _toggle(plugin, value),
                    ),
                    if (!plugin.builtIn)
                      IconButton(
                        tooltip: '卸载插件',
                        onPressed: _busy ? null : () => _uninstall(plugin),
                        icon: const Icon(Icons.delete_outline),
                      ),
                  ],
                ),
              ),
            ),
      ],
    ),
  );
}
