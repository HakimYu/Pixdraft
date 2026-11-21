import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/image_validation.dart';
import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/plugin_contract.dart';
import '../../plugins/plugin_registry.dart';
import 'plugin_fields_form.dart';
import 'plugin_toolkit.dart';

export 'plugin_toolkit.dart';

Future<PluginToolkit> _defaultToolkit(StudioStore store) async {
  final registry = await PluginRegistry.load(store);
  return PluginToolkit(tools: registry.tools, process: registry.process, dispose: registry.dispose);
}

class PluginToolsPage extends StatefulWidget {
  const PluginToolsPage({super.key, required this.store, this.initialImages = const [], this.loader});
  final StudioStore store;
  final List<ImageAsset> initialImages;
  final PluginToolkitLoader? loader;

  @override
  State<PluginToolsPage> createState() => _PluginToolsPageState();
}

class _PluginToolsPageState extends State<PluginToolsPage> {
  PluginToolkit? _toolkit;
  String? _error;
  List<ImageAsset> _images = [];

  @override
  void initState() {
    super.initState();
    _images = widget.initialImages;
    _load();
  }

  @override
  void dispose() {
    _toolkit?.dispose?.call();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final toolkit = await (widget.loader ?? _defaultToolkit)(widget.store);
      if (!mounted) return;
      setState(() => _toolkit = toolkit);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '读取本地工具失败，请重试');
    }
  }

  void _add(List<ImageAsset> assets) {
    final ids = _images.map((e) => e.id).toSet();
    setState(() => _images = [..._images, ...assets.where((asset) => ids.add(asset.id))]);
  }

  Future<void> _pickLocal() async {
    try {
      final files = await ImagePicker().pickMultiImage(limit: 20);
      final added = <ImageAsset>[];
      for (final file in files.take(20)) {
        if (await file.length() > 64 * 1024 * 1024) throw const FormatException('图片超过 64 MB');
        final bytes = await file.readAsBytes();
        added.add(await widget.store.saveAsset(bytes, detectImageMime(bytes)));
      }
      if (!mounted) return;
      _add(added);
    } on FormatException catch (error) {
      _toast(error.message);
    } catch (_) {
      _toast('无法读取所选图片');
    }
  }

  Future<void> _pickFromStudio() async {
    final picked = await showModalBottomSheet<List<ImageAsset>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _StudioAssetPicker(store: widget.store),
    );
    if (picked != null && mounted) _add(picked);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final toolkit = _toolkit;
    return Scaffold(
      appBar: AppBar(title: const Text('本地处理')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('待处理图片（${_images.length} 张）', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_images.isNotEmpty) ...[
                    SizedBox(
                      height: 76,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _images.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 12),
                        itemBuilder: (context, index) {
                          final asset = _images[index];
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: 76, height: 76, child: _thumb(asset))),
                              Positioned(
                                right: -8,
                                top: -8,
                                child: IconButton(
                                  tooltip: '移除这张图片',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.cancel, size: 20),
                                  onPressed: () => setState(() => _images = [..._images]..removeAt(index)),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(onPressed: _pickFromStudio, icon: const Icon(Icons.collections_outlined), label: const Text('从作品选择')),
                      OutlinedButton.icon(onPressed: _pickLocal, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('本地图片')),
                    ],
                  ),
                  if (_images.isNotEmpty) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => setState(() => _images = []), child: const Text('清空'))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(_error!),
                trailing: TextButton(onPressed: _load, child: const Text('重试')),
              ),
            )
          else if (toolkit == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (toolkit.tools.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('还没有可用的本地工具，安装插件后即可使用')))
          else
            for (final tool in toolkit.tools)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: const Icon(Icons.auto_fix_high_outlined),
                  title: Text(tool.name),
                  subtitle: Text(_images.isEmpty ? '先添加图片' : '处理 ${_images.length} 张图片'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (_images.isEmpty) return _toast('请先添加要处理的图片');
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ToolRunPage(store: widget.store, toolkit: toolkit, tool: tool, images: List.of(_images))));
                  },
                ),
              ),
        ],
      ),
    );
  }

  Widget _thumb(ImageAsset asset) {
    final placeholder = const Center(child: Icon(Icons.image_outlined));
    try {
      return Image.file(widget.store.fileFor(asset), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } catch (_) {
      return placeholder;
    }
  }
}

class ToolRunPage extends StatefulWidget {
  const ToolRunPage({super.key, required this.store, required this.toolkit, required this.tool, required this.images});
  final StudioStore store;
  final PluginToolkit toolkit;
  final ToolDescriptor tool;
  final List<ImageAsset> images;

  @override
  State<ToolRunPage> createState() => _ToolRunPageState();
}

class _ToolRunPageState extends State<ToolRunPage> {
  Map<String, dynamic> _values = {};
  final List<_ToolResult> _results = [];
  bool _running = false, _cancelled = false;
  int _done = 0;
  String? _error;

  Future<void> _run() async {
    final error = validatePluginFieldValues(widget.tool.fields, _values);
    if (error != null) return setState(() => _error = error);
    setState(() {
      _error = null;
      _running = true;
      _cancelled = false;
      _done = 0;
      _results.clear();
    });
    final step = ProcessingStep(pluginId: widget.tool.pluginId, version: widget.tool.version, processorId: widget.tool.processorId, params: Map.of(_values));
    var cancelled = false;
    for (final image in widget.images) {
      if (_cancelled) {
        cancelled = true;
        break;
      }
      _ToolResult result;
      try {
        final output = await widget.toolkit.process(image, step, isCancelled: () => _cancelled);
        if (_cancelled) {
          cancelled = true;
          break;
        }
        await widget.store.recordDerivedImage(source: image, result: output, step: step);
        result = _ToolResult(source: image, output: output);
      } catch (error) {
        if (_cancelled) {
          cancelled = true;
          break;
        }
        result = _ToolResult(source: image, error: error is FormatException ? error.message : '处理失败，请重试');
      }
      if (!mounted) return;
      setState(() {
        _results.add(result);
        _done++;
      });
    }
    if (!mounted) return;
    setState(() => _running = false);
    final failed = _results.where((item) => item.error != null).length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(cancelled ? '已取消，完成的 ${_results.length} 张已保存到作品' : failed == 0 ? '处理完成，结果已保存到作品' : '完成 ${_results.length - failed} 张，失败 $failed 张')));
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.length;
    return Scaffold(
      appBar: AppBar(title: Text(widget.tool.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.tool.pluginId} · ${widget.tool.version}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          PluginFieldsForm(fields: widget.tool.fields, onChanged: (values) => _values = values, enabled: !_running),
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
          ],
          if (_running) ...[
            LinearProgressIndicator(value: total == 0 ? null : _done / total),
            const SizedBox(height: 8),
            Text('正在处理 ${(_done + 1).clamp(1, total)} / $total'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => setState(() => _cancelled = true), child: const Text('取消')),
          ] else
            FilledButton(onPressed: _run, child: Text(total > 1 ? '处理 $total 张图片' : '开始处理')),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('处理结果', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 48, height: 48, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: item.output == null ? const Icon(Icons.error_outline) : _thumb(item.output!))),
                title: Text(item.error ?? '已保存到作品'),
                subtitle: Text('源图 ${item.source.id.substring(0, item.source.id.length.clamp(0, 8))}'),
                trailing: item.output?.width == null || item.output?.height == null ? null : Text('${item.output!.width}×${item.output!.height}'),
              ),
          ],
        ],
      ),
    );
  }

  Widget _thumb(ImageAsset asset) {
    final placeholder = const Center(child: Icon(Icons.image_outlined));
    try {
      return Image.file(widget.store.fileFor(asset), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } catch (_) {
      return placeholder;
    }
  }
}

class _ToolResult {
  _ToolResult({required this.source, this.output, this.error});
  final ImageAsset source;
  final ImageAsset? output;
  final String? error;
}

class _StudioAssetPicker extends StatefulWidget {
  const _StudioAssetPicker({required this.store});
  final StudioStore store;

  @override
  State<_StudioAssetPicker> createState() => _StudioAssetPickerState();
}

class _StudioAssetPickerState extends State<_StudioAssetPicker> {
  final _selected = <String, ImageAsset>{};
  List<ImageAsset> _assets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tasks = await widget.store.tasks();
      final seen = <String>{};
      final assets = <ImageAsset>[
        for (final task in tasks)
          if (task.deletedAt == null)
            for (final asset in task.outputs)
              if (seen.add(asset.id)) asset,
      ];
      if (!mounted) return;
      setState(() {
        _assets = assets;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('从作品选择（已选 ${_selected.length} 张）', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (_assets.isEmpty)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('还没有作品，先导入或生成图片')))
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _assets.length,
                itemBuilder: (context, index) {
                  final asset = _assets[index];
                  return CheckboxListTile(
                    value: _selected.containsKey(asset.id),
                    title: Text(asset.id.substring(0, asset.id.length.clamp(0, 8))),
                    subtitle: Text('${asset.mime} · ${(asset.bytes / 1024).round()} KB'),
                    secondary: SizedBox(width: 48, height: 48, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: _thumb(asset))),
                    onChanged: (value) => setState(() => value == true ? _selected[asset.id] = asset : _selected.remove(asset.id)),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _selected.isEmpty ? null : () => Navigator.of(context).pop(_selected.values.toList()), child: const Text('添加所选图片')),
        ],
      ),
    ),
  );

  Widget _thumb(ImageAsset asset) {
    final placeholder = const Center(child: Icon(Icons.image_outlined));
    try {
      return Image.file(widget.store.fileFor(asset), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder);
    } catch (_) {
      return placeholder;
    }
  }
}