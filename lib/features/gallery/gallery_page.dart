import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'error_details.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../studio_image.dart';

import '../../data/studio_store.dart';
import 'package:file_picker/file_picker.dart';
import '../../data/image_validation.dart';
import '../../platform/background_tasks.dart';
import '../../platform/local_file_picker.dart';
import '../../platform/media.dart';
import '../../models/models.dart';
import '../editor/image_editor_page.dart';
import '../plugins/plugin_tools_page.dart';
import '../../tasks/recover_downloads.dart';

Rect? _shareOrigin(BuildContext? context) {
  final box = context?.findRenderObject();
  return box is RenderBox && box.attached && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
}
const taskLabels = <TaskStatus, String>{
  TaskStatus.queued: '排队中', TaskStatus.running: '生成中',
  TaskStatus.done: '已完成', TaskStatus.error: '失败',
  TaskStatus.partialError: '部分完成', TaskStatus.aborted: '已取消',
  TaskStatus.interrupted: '已中断',
};

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key, required this.store, required this.reuse, required this.retry, required this.cancel, this.resumeRemote, this.trash = false, this.title, this.headerActions = const [], this.composer, this.sidebar});
  final StudioStore store;
  final bool trash;
  final String? title;
  final List<Widget> headerActions;
  final Widget? composer, sidebar;
  final ValueChanged<GenerationInput> reuse;
  final Future<void> Function(String) retry, cancel;
  final Future<void> Function(String)? resumeRemote;
  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<StudioTask> _tasks = [];
  List<Map<String, Object?>> _categories = [];
  final _selected = <String>{};
  final _batchMenuKey = GlobalKey();
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  String _search = '';
  TaskStatus? _status;
  String? _category, _error;
  bool _favorites = false, _pure = false, _loading = true;
  bool get _trash => widget.trash;
  Future<void>? _reloadInFlight;
  bool _reloadRequested = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_reload);
    unawaited(_reload());
  }
  @override
  void dispose() {
    widget.store.removeListener(_reload);
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }
  Future<void> _reload() {
    _reloadRequested = true;
    return _reloadInFlight ??= _readGallery().whenComplete(() => _reloadInFlight = null);
  }

  Future<void> _readGallery() async {
    while (mounted && _reloadRequested) {
      _reloadRequested = false;
      try {
        final tasks = await widget.store.tasks();
        final categories = await widget.store.categories();
        if (!mounted) return;
        setState(() { _tasks = tasks; _categories = categories; _loading = false; _error = null; });
      } catch (_) {
        if (mounted) setState(() { _error = '读取作品失败，请重试'; _loading = false; });
      }
    }
  }
  Future<void> _act(Future<void> Function() action) async {
    try { await action(); } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  }
  List<StudioTask> get _visible => _tasks.where((t) =>
    (t.deletedAt != null) == _trash && (!_favorites || t.favorite) &&
    (_status == null || t.status == _status) &&
    (_category == null || (_category == '' ? t.categoryId == null : t.categoryId == _category)) &&
    '${t.input.prompt} ${t.input.provider.name} ${taskLabels[t.status]} ${t.input.params.toJson().values.join(' ')} ${_categories.where((c) => c['id'] == t.categoryId).firstOrNull?['name'] ?? ''}'.toLowerCase().contains(_search.toLowerCase())
  ).toList();

  Future<void> _importImage() => _act(() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'], webOptions: localFilePickerOptions());
    final providers = await widget.store.providers();
    final provider = providers.where((p) => p.enabled).firstOrNull ?? const ProviderConfig(id: 'local-import', name: '本地导入', baseUrl: 'https://local.invalid');
    for (final file in files) {
      final length = await file.length();
      if (length == null || length > 64 * 1024 * 1024) throw const FormatException('无法确认图片大小或图片超过 64 MB');
      final bytes = await file.readAsBytes();
      final asset = await widget.store.saveAsset(bytes, detectImageMime(bytes));
      await widget.store.importAsset(asset, provider);
    }
  });
  Future<void> _openPlugins() async {
    final assets = {for (final t in _tasks.where((t) => _selected.contains(t.id))) for (final a in t.outputs) a.id: a}.values.toList();
    if (assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('所选任务没有图片')));
      return;
    }
    setState(_selected.clear);
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PluginToolsPage(store: widget.store, initialImages: assets)));
  }
  Future<void> _shareSelected() => _act(() async {
    final assets = {for (final t in _tasks.where((t) => _selected.contains(t.id))) for (final a in t.outputs) a.id: a}.values;
    if (assets.isEmpty) throw StateError('所选任务没有图片');
    final origin = _shareOrigin(_batchMenuKey.currentContext);
    try {
      await shareImages(widget.store, assets, shareOrigin: origin);
    } on UnsupportedError {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(fileShareAlternative)));
    }
  });
  @override
  Widget build(BuildContext context) {
    final tasks = _visible;
    final images = [for (final task in tasks) for (final (index, asset) in task.outputs.indexed) (task: task, asset: asset, index: index)];
    return Scaffold(
      resizeToAvoidBottomInset: widget.composer == null,
      appBar: AppBar(title: Text(_trash ? '回收站' : widget.title ?? '作品'), actions: widget.headerActions),
      bottomNavigationBar: _trash ? null : widget.composer,
      body: SafeArea(top: false, bottom: widget.composer == null, child: Row(children: [
        if (widget.sidebar != null) ...[
          widget.sidebar!,
          const VerticalDivider(width: 1),
        ],
        Expanded(key: const ValueKey('gallery-results'), child: LayoutBuilder(builder: (context, constraints) {
          final filters = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: TextField(controller: _searchController, onChanged: (v) => setState(() => _search = v), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: '搜索提示词、参数、供应商、分类…', suffixIcon: _search.isEmpty ? null : IconButton(tooltip: '清空搜索', onPressed: () { _searchController.clear(); setState(() => _search = ''); }, icon: const Icon(Icons.close))))),
        SizedBox(height: 56, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(label: const Text('收藏'), selected: _favorites, onSelected: (v) => setState(() => _favorites = v))),
          Padding(padding: const EdgeInsets.only(right: 8), child: PopupMenuButton<String>(tooltip: '筛选状态', onSelected: (v) => setState(() => _status = v == 'all' ? null : TaskStatus.values.byName(v)), itemBuilder: (_) => [const PopupMenuItem(value: 'all', child: Text('全部状态')), for (final entry in taskLabels.entries) PopupMenuItem(value: entry.key.name, child: Text(entry.value))], child: Chip(avatar: const Icon(Icons.tune, size: 18), label: Text(_status == null ? '全部状态' : taskLabels[_status]!)))),
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: const Text('全部分类'), selected: _category == null, onSelected: (_) => setState(() => _category = null))),
          Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: const Text('未分类'), selected: _category == '', onSelected: (_) => setState(() => _category = ''))),
          for (final c in _categories) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(c['name'] as String), selected: _category == c['id'], onSelected: (_) => setState(() => _category = c['id'] as String))),
        ])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          Expanded(child: Text(_selected.isEmpty ? '${tasks.length} 个任务' : '已选择 ${_selected.length} 项', style: Theme.of(context).textTheme.bodySmall)),
          if (_selected.isNotEmpty) ...[
            IconButton(tooltip: '全选当前结果', onPressed: () => setState(() => _selected.addAll(tasks.map((t) => t.id))), icon: const Icon(Icons.select_all)),
            PopupMenuButton<String>(key: _batchMenuKey, tooltip: '批量操作', onSelected: _batchAction, itemBuilder: (_) => [
              const PopupMenuItem(value: 'favorite', child: Text('批量收藏')),
              const PopupMenuItem(value: 'unfavorite', child: Text('取消收藏')),
              if (!kIsWeb) const PopupMenuItem(value: 'share', child: Text('批量导出图片')),
              if (!kIsWeb) const PopupMenuItem(value: 'plugins', child: Text('本地处理图片')),
              const PopupMenuItem(value: 'category', child: Text('设置分类')),
              PopupMenuItem(value: 'trash', child: Text(_trash ? '恢复' : '移入回收站')),
              if (_trash) const PopupMenuItem(value: 'purge', child: Text('永久删除')),
            ]),
            IconButton(tooltip: '取消选择', onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close)),
          ] else ...[
            IconButton(tooltip: '导入图片', onPressed: _importImage, icon: const Icon(Icons.add_photo_alternate_outlined)),
            IconButton(tooltip: _pure ? '显示任务信息' : '纯图模式', onPressed: () => setState(() => _pure = !_pure), icon: Icon(_pure ? Icons.view_agenda_outlined : Icons.grid_view_outlined)),
            if (!_trash) IconButton(tooltip: '回收站', icon: const Icon(Icons.delete_outline), onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => GalleryPage(store: widget.store, reuse: widget.reuse, retry: widget.retry, resumeRemote: widget.resumeRemote, cancel: widget.cancel, trash: true)))),
          ],
        ])),
        if (_error != null) ListTile(title: Text(_error!), trailing: TextButton(onPressed: _reload, child: const Text('重试'))),
          ]);
          return Column(children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight * .6),
              child: SingleChildScrollView(primary: false, child: filters),
            ),
            Expanded(child: _results(tasks, images, (constraints.maxWidth / 330).floor().clamp(1, 5))),
          ]);
        })),
      ])),
    );
  }

  Widget _results(List<StudioTask> tasks, List<({StudioTask task, ImageAsset asset, int index})> images, int columns) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (tasks.isEmpty) {
      final message = _trash
          ? '回收站为空，删除的作品会保留 15 天'
          : _search.isNotEmpty || _favorites || _status != null || _category != null
          ? '没有符合条件的任务'
          : '还没有作品，写下提示词开始生成';
      return Center(child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(_trash ? Icons.delete_outline : Icons.image_outlined, size: 42, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
        ]),
      ));
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(controller: _scroll, thumbVisibility: true, child: RefreshIndicator(
      onRefresh: _reload,
      child: _pure
        ? images.isEmpty
          ? ListView(controller: _scroll, children: const [Padding(padding: EdgeInsets.all(32), child: Text('任务尚无图片，请切换任务模式查看进度'))])
          : GridView.builder(controller: _scroll, padding: const EdgeInsets.all(12), gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, crossAxisSpacing: 8, mainAxisSpacing: 8), itemCount: images.length, itemBuilder: (_, i) => _card(images[i].task, asset: images[i].asset, outputIndex: images[i].index))
        : ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            itemCount: (tasks.length + columns - 1) ~/ columns,
            itemBuilder: (_, row) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var col = 0; col < columns; col++)
                Expanded(child: row * columns + col < tasks.length ? _card(tasks[row * columns + col]) : const SizedBox.shrink()),
            ]),
          ),
    )));
  }
  Widget _card(StudioTask task, {ImageAsset? asset, int? outputIndex}) {
    final selected = _selected.contains(task.id);
    final active = task.status == TaskStatus.running || task.status == TaskStatus.queued;
    void toggle() => setState(() { if (selected) { _selected.remove(task.id); } else { _selected.add(task.id); } });
    final preview = BackgroundTasks.previews[task.id];
    Widget image = asset != null ? assetImage(widget.store, asset) : task.outputs.isNotEmpty ? assetImage(widget.store, task.outputs.first) : preview != null && active ? Image.memory(preview, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, _, _) => const Icon(Icons.image_outlined)) : Icon(active ? Icons.hourglass_top : Icons.image_outlined, color: Theme.of(context).colorScheme.outline);
    final favorite = IconButton(tooltip: task.favorite ? '取消收藏' : '收藏', onPressed: () => _act(() => widget.store.updateTask(task.id, {'favorite': task.favorite ? 0 : 1})), icon: Icon(task.favorite ? Icons.favorite : Icons.favorite_border, size: 20));
    return Card(key: ValueKey('task-${task.id}-${outputIndex ?? 'card'}'), clipBehavior: Clip.antiAlias, color: selected ? Theme.of(context).colorScheme.secondaryContainer : null, child: InkWell(
      onLongPress: toggle,
      onTap: () { if (_selected.isNotEmpty) { toggle(); } else { _detail(task.id, assetId: asset?.id, outputIndex: outputIndex); } },
      child: asset != null ? Stack(fit: StackFit.expand, children: [image, Positioned(top: 0, right: 0, child: favorite), if (selected) const Positioned(top: 8, left: 8, child: Icon(Icons.check_circle))]) : Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 100, height: 112, child: Stack(children: [
            Positioned.fill(child: Container(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(10)), clipBehavior: Clip.antiAlias, child: GestureDetector(onTap: () { if (_selected.isNotEmpty) { toggle(); } else if (task.outputs.isNotEmpty) { openImagePreview(context, widget.store, task.outputs); } else { _detail(task.id); } }, child: image))),
            Positioned(top: 0, left: 0, child: favorite),
            Positioned(top: 0, right: 0, child: IconButton(tooltip: selected ? '取消选择任务' : '选择任务', onPressed: toggle, icon: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, size: 20))),
            if (task.outputs.length > 1) Positioned(bottom: 4, right: 4, child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), child: Text('${task.outputs.length} 张', style: const TextStyle(color: Colors.white, fontSize: 11)))),
          ])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.input.prompt.isEmpty ? '图片编辑' : task.input.prompt, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('${taskLabels[task.status]} · ${task.input.provider.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('${task.input.params.size} · ${task.input.params.quality} · ${task.input.params.format.toUpperCase()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('${task.createdAt.toLocal()}'.split('.').first, style: Theme.of(context).textTheme.labelSmall),
          ])),
        ])),
        if (task.error != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 4), child: ErrorDetails(message: task.error!)),
        if (active) const LinearProgressIndicator(minHeight: 2),
        Padding(padding: const EdgeInsets.fromLTRB(8, 0, 4, 4), child: Wrap(alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, spacing: 2, children: [
          if (!_trash) IconButton(tooltip: '复用配置', onPressed: () => widget.reuse(task.input), icon: const Icon(Icons.reply, size: 20)),
          if (!_trash && task.outputs.isNotEmpty) IconButton(tooltip: '编辑输出', onPressed: () => _editTask(task), icon: const Icon(Icons.edit_outlined, size: 20)),
          if (!_trash && active) IconButton(tooltip: '停止生成', onPressed: () => _act(() => widget.cancel(task.id)), icon: const Icon(Icons.stop_circle_outlined, size: 20)),
          if (!_trash && !active) IconButton(tooltip: '重试生成', onPressed: () => _retryTask(task), icon: const Icon(Icons.refresh, size: 20)),
          if (!active) IconButton(tooltip: _trash ? '恢复记录' : '移入回收站', onPressed: () => _taskAction(task, 'trash'), icon: Icon(_trash ? Icons.restore : Icons.delete_outline, size: 20)),
          if (_trash && !active) IconButton(tooltip: '永久删除', onPressed: () => _purge([task.id]), icon: const Icon(Icons.close, size: 20)),
          PopupMenuButton<String>(tooltip: '任务操作', onSelected: (value) => _taskAction(task, value), itemBuilder: (_) => [
            const PopupMenuItem(value: 'detail', child: Text('查看详情')),
            if (!_trash) const PopupMenuItem(value: 'category', child: Text('设置分类')),
          ]),
        ])),
      ]),
    ));
  }

  Future<void> _retryTask(StudioTask task) async {
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('重新生成？'), content: const Text('会重新调用供应商并可能再次计费，已有图片会保留。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新生成'))]));
    if (confirm == true) await _act(() => widget.retry(task.id));
  }
  Future<void> _editTask(StudioTask task) async {
    final asset = task.outputs.first;
    final result = await Navigator.push<ImageEditResult>(context, MaterialPageRoute(builder: (_) => ImageEditorPage(store: widget.store, source: asset)));
    if (result != null && mounted) widget.reuse(GenerationInput(taskId: newId(), provider: task.input.provider, prompt: task.input.prompt, params: task.input.params, references: [asset], mask: result.mask, markup: result.markup, parentTaskId: task.id, parentAssetId: asset.id));
  }
  Future<void> _taskAction(StudioTask task, String action) async {
    if (action == 'detail') { await _detail(task.id); return; }
    if (action == 'category') { setState(() { _selected.clear(); _selected.add(task.id); }); await _moveCategory(); return; }
    if (action == 'purge') { await _purge([task.id]); return; }
    await _act(() => widget.store.updateTask(task.id, {'deleted_at': _trash ? null : DateTime.now().toUtc().toIso8601String()}));
  }
  Future<void> _batchAction(String action) async {
    if (action == 'share') { await _shareSelected(); return; }
    if (action == 'plugins') { await _openPlugins(); return; }
    if (action == 'category') { await _moveCategory(); return; }
    if (action == 'trash') { await _batchTrash(!_trash); return; }
    if (action == 'purge') { await _purge(_selected.toList()); return; }
    await _act(() async { for (final id in _selected.toList()) { await widget.store.updateTask(id, {'favorite': action == 'favorite' ? 1 : 0}); } });
  }
  Future<void> _purge(List<String> ids) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('永久删除？'), content: Text('将永久删除 ${ids.length} 个任务及不再引用的图片，此操作不可撤销。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('永久删除'))]));
    if (confirmed != true) return;
    await _act(() async { for (final id in ids) { await widget.store.purgeTask(id); } if (mounted) setState(_selected.clear); });
  }
  Future<void> _batchTrash(bool trash) async {
    final ids = Set.of(_selected);
    await _act(() async {
      for (final id in ids) {
        final task = _tasks.firstWhere((t) => t.id == id);
        if (task.status == TaskStatus.running || task.status == TaskStatus.queued) throw StateError('请先停止任务');
        await widget.store.updateTask(id, {'deleted_at': trash ? DateTime.now().toUtc().toIso8601String() : null});
      }
      if (mounted) setState(_selected.clear);
    });
  }
  Future<void> _moveCategory() async {
    final category = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: ListView(shrinkWrap: true, children: [ListTile(title: const Text('不分类'), onTap: () => Navigator.pop(context, '')), for (final c in _categories) ListTile(title: Text(c['name'] as String), onTap: () => Navigator.pop(context, c['id'] as String))])));
    if (category == null) return;
    await _act(() async { for (final id in _selected.toList()) { await widget.store.updateTask(id, {'category_id': category.isEmpty ? null : category}); } });
    if (mounted) setState(_selected.clear);
  }
  Future<void> _detail(String id, {String? assetId, int? outputIndex}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TaskDetailPage(store: widget.store, taskId: id, reuse: widget.reuse, retry: widget.retry, resumeRemote: widget.resumeRemote, cancel: widget.cancel, initialAssetId: assetId, initialOutputIndex: outputIndex)));
  }
}

class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({super.key, required this.store, required this.taskId, required this.reuse, required this.retry, required this.cancel, this.resumeRemote, this.initialAssetId, this.initialOutputIndex});
  final StudioStore store;
  final String taskId;
  final String? initialAssetId;
  final int? initialOutputIndex;
  final ValueChanged<GenerationInput> reuse;
  final Future<void> Function(String) retry, cancel;
  final Future<void> Function(String)? resumeRemote;
  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}
class _TaskDetailPageState extends State<TaskDetailPage> {
  final _outputKey = GlobalKey();
  StudioTask? _task;
  bool _canResume = false;
  String? _error;
  int _loadRevision = 0;
  bool _saving = false;
  int _index = 0;
  bool _positioned = false;
  PageController? _pagerController;
  PageController get _pager => _pagerController ??= PageController(initialPage: _index + (_task!.outputs.length > 1 ? 1 : 0));
  @override
  void initState() { super.initState(); widget.store.addListener(_load); unawaited(_load()); }
  @override
  void dispose() { widget.store.removeListener(_load); _pagerController?.dispose(); super.dispose(); }
  Future<void> _load() async {
    final revision = ++_loadRevision;
    try {
      final task = await widget.store.task(widget.taskId);
      final canResume = widget.resumeRemote != null && task != null && task.deletedAt == null &&
          ([TaskStatus.error, TaskStatus.partialError, TaskStatus.interrupted].contains(task.status)) &&
          (await widget.store.remoteCheckpoints(task.id, task.attempt)).isNotEmpty;
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        if (!_positioned && task != null) {
          _positioned = true;
          final at = widget.initialOutputIndex ?? task.outputs.indexWhere((a) => a.id == widget.initialAssetId);
          _index = at < 0 ? 0 : at;
        }
        if (task != null && _index >= task.outputs.length) _index = task.outputs.isEmpty ? 0 : task.outputs.length - 1;
        _task = task;
        _canResume = canResume;
        _error = task == null ? '该任务已被永久删除' : null;
      });
      final page = _index + ((task?.outputs.length ?? 0) > 1 ? 1 : 0);
      if (_pagerController?.hasClients == true && _pager.page?.round() != page) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && revision == _loadRevision && _pagerController?.hasClients == true) _pager.jumpToPage(page);
        });
      }
    } catch (_) {
      if (mounted && revision == _loadRevision) setState(() => _error = '无法读取任务');
    }
  }
  Future<void> _saveImage(ImageAsset asset) async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      final saved = await saveImageToDevice(widget.store, asset);
      if (saved && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(kIsWeb ? '已发起浏览器下载' : '图片已保存')));
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '保存失败，请检查存储空间');
    } catch (_) {
      if (mounted) setState(() => _error = '无法保存图片，请确认本地图片存在且存储空间充足');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
  Future<void> _action(Future<void> Function() action) async {
    try { await action(); } catch (_) { if (mounted) setState(() => _error = '操作失败，请检查供应商或存储空间'); }
  }
  @override
  Widget build(BuildContext context) {
    final task = _task;
    if (task == null) return Scaffold(appBar: AppBar(title: const Text('作品详情')), body: Center(child: Text(_error ?? '正在读取…')));
    final active = [TaskStatus.queued, TaskStatus.running].contains(task.status);
    final info = <Widget>[
      if (active) const LinearProgressIndicator(),
      if (active && BackgroundTasks.previews[task.id] != null) ...[const SizedBox(height: 12), Image.memory(BackgroundTasks.previews[task.id]!, fit: BoxFit.contain, height: 280, gaplessPlayback: true, errorBuilder: (_, _, _) => const Text('正在生成预览…')), const Text('临时预览 · 最终图片生成后自动保存')],
      SelectableText(task.input.prompt, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      Text('${task.input.provider.name} · ${task.input.params.size} · ${task.input.params.quality} · ${task.input.params.format}'),
      Text('${task.createdAt.toLocal()} · 第 ${task.attempt} 次执行'),
      if (task.error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: ErrorDetails(message: task.error!)),
      if (_error != null) Text(_error!),
      const SizedBox(height: 20),
      Wrap(spacing: 12, runSpacing: 12, children: [
        if (active) OutlinedButton.icon(onPressed: () => _action(() => widget.cancel(task.id)), icon: const Icon(Icons.stop), label: const Text('取消任务')),
        if (_canResume) OutlinedButton.icon(onPressed: () => _action(() => widget.resumeRemote!(task.id)), icon: const Icon(Icons.sync), label: const Text('继续查询远端结果')),
        if (!active && task.deletedAt == null) OutlinedButton.icon(onPressed: () async {
          final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('重新生成？'), content: const Text('将使用原始参数再次请求，可能产生新的费用。已有图片会保留。若只是下载失败，请使用重新下载。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新生成'))]));
          if (confirmed == true) await _action(() => widget.retry(task.id));
        }, icon: const Icon(Icons.refresh), label: const Text('原位重试')),
        if (!active) OutlinedButton.icon(onPressed: () => _action(() async { final count = await retrySavedDownloads(widget.store, task.id); if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(count == 0 ? '没有待下载的结果' : '已恢复 $count 张图片'))); }), icon: const Icon(Icons.cloud_download_outlined), label: const Text('重新下载已有结果')),
        OutlinedButton.icon(onPressed: () { widget.reuse(task.input); Navigator.pop(context); }, icon: const Icon(Icons.tune), label: const Text('复用参数')),
        if (!active) OutlinedButton.icon(onPressed: () => _action(() => widget.store.updateTask(task.id, {'deleted_at': task.deletedAt == null ? DateTime.now().toUtc().toIso8601String() : null})), icon: Icon(task.deletedAt == null ? Icons.delete_outline : Icons.restore), label: Text(task.deletedAt == null ? '移入回收站' : '恢复')),
        if (task.deletedAt != null && !active) TextButton(onPressed: () async { final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: const Text('彻底删除此任务？'), content: const Text('此操作不可撤销。'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('彻底删除'))])); if (confirmed == true) { await _action(() => widget.store.purgeTask(task.id)); if (context.mounted) Navigator.pop(context); } }, child: const Text('彻底删除')),
      ]),
    ];
    final more = <Widget>[
      if (task.input.parentTaskId != null) ListTile(leading: const Icon(Icons.account_tree_outlined), title: const Text('查看来源任务'), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TaskDetailPage(store: widget.store, taskId: task.input.parentTaskId!, reuse: widget.reuse, retry: widget.retry, resumeRemote: widget.resumeRemote, cancel: widget.cancel)))),
      ExpansionTile(title: const Text('参数快照'), children: [SelectableText(const JsonEncoder.withIndent('  ').convert(task.input.toJson()))]),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(taskLabels[task.status]!), actions: [IconButton(tooltip: '复制提示词', onPressed: () => Clipboard.setData(ClipboardData(text: task.input.prompt)), icon: const Icon(Icons.copy))]),
      body: SafeArea(top: false, child: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860 && task.outputs.isNotEmpty;
        final output = task.outputs.isEmpty ? null : KeyedSubtree(
          key: _outputKey,
          child: _outputSection(task, previewHeight: wide ? (constraints.maxHeight - 144).clamp(180.0, 760.0) : 360),
        );
        return ListView(padding: const EdgeInsets.all(16), children: [
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: output!),
              const SizedBox(width: 24),
              SizedBox(width: (constraints.maxWidth * .33).clamp(300.0, 420.0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...info, ...more])),
            ])
          else ...[...info, ?output, ...more],
        ]);
      })),
    );
  }
  Widget _outputSection(StudioTask task, {required double previewHeight}) {
    final outputs = task.outputs;
    final index = _index < outputs.length ? _index : outputs.length - 1;
    final asset = outputs[index];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      SizedBox(height: previewHeight, child: _loopingPages(controller: _pager, count: outputs.length, onChanged: (value) => setState(() => _index = value), itemBuilder: (_, i) => GestureDetector(onTap: () => openImagePreview(context, widget.store, outputs, initialIndex: i), child: assetImage(widget.store, outputs[i])))),
      if (outputs.length > 1) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(tooltip: '上一张', onPressed: () => _pager.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut), icon: const Icon(Icons.chevron_left)),
        Text('${index + 1}/${outputs.length}'),
        IconButton(tooltip: '下一张', onPressed: () => _pager.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut), icon: const Icon(Icons.chevron_right)),
      ]),
      TextButton.icon(onPressed: _saving ? null : () => _saveImage(asset), icon: const Icon(Icons.download_outlined), label: Text(_saving ? '正在保存…' : '保存到设备')),
      Wrap(children: [
        if (supportsFileShare) Builder(builder: (anchorContext) => TextButton.icon(
          onPressed: () => _action(() async {
            try {
              await shareImages(widget.store, [asset], shareOrigin: _shareOrigin(anchorContext));
            } on UnsupportedError {
              if (mounted) setState(() => _error = fileShareAlternative);
            }
          }),
          icon: const Icon(Icons.ios_share), label: const Text('分享 / 导出'),
        )),
        TextButton.icon(onPressed: () { widget.reuse(GenerationInput(taskId: newId(), provider: task.input.provider, prompt: task.input.prompt, params: task.input.params, references: [asset], parentTaskId: task.id, parentAssetId: asset.id)); Navigator.pop(context); }, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('作为参考图')),
        TextButton.icon(onPressed: () => _editOutput(task, asset), icon: const Icon(Icons.draw_outlined), label: const Text('编辑这张')),
        if (!kIsWeb) TextButton.icon(onPressed: () => _openPluginToolsFor(asset), icon: const Icon(Icons.tune), label: const Text('本地处理')),
      ]),
    ]);
  }
  void _openPluginToolsFor(ImageAsset asset) => Navigator.push<void>(context, MaterialPageRoute(builder: (_) => PluginToolsPage(store: widget.store, initialImages: [asset])));
  Future<void> _editOutput(StudioTask task, ImageAsset asset) async {
    final result = await Navigator.push<ImageEditResult>(context, MaterialPageRoute(builder: (_) => ImageEditorPage(store: widget.store, source: asset)));
    if (result == null || !mounted) return;
    widget.reuse(GenerationInput(taskId: newId(), provider: task.input.provider, prompt: task.input.prompt, params: task.input.params, references: [asset], mask: result.mask, markup: result.markup, parentTaskId: task.id, parentAssetId: asset.id));
    Navigator.pop(context);
  }
}

void openImagePreview(BuildContext context, StudioStore store, List<ImageAsset> assets, {int initialIndex = 0}) {
  if (assets.isEmpty) return;
  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _ImageViewer(store: store, assets: assets, initialIndex: initialIndex)));
}

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.store, required this.assets, required this.initialIndex});
  final StudioStore store;
  final List<ImageAsset> assets;
  final int initialIndex;
  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}
class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _pager = PageController(initialPage: widget.initialIndex + (widget.assets.length > 1 ? 1 : 0));
  late int _index = widget.initialIndex;
  @override
  void dispose() { _pager.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final assets = widget.assets;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        _loopingPages(controller: _pager, count: assets.length, physics: const NeverScrollableScrollPhysics(), onChanged: (i) => setState(() => _index = i), itemBuilder: (_, i) => _ZoomableImage(key: ValueKey('$i-$_index'), store: widget.store, asset: assets[i], onSwipe: (next) {
          if (assets.length < 2) return;
          if (next) {
            _pager.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          } else {
            _pager.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          }
        })),
        SafeArea(child: Align(alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.all(12), child: IconButton.filled(tooltip: '关闭预览', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close))))),
        if (assets.length > 1) SafeArea(child: Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.all(12), child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton.filledTonal(tooltip: '上一张', onPressed: () => _pager.previousPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut), icon: const Icon(Icons.chevron_left)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('${_index + 1}/${assets.length}', style: const TextStyle(color: Colors.white))),
          IconButton.filledTonal(tooltip: '下一张', onPressed: () => _pager.nextPage(duration: const Duration(milliseconds: 200), curve: Curves.easeOut), icon: const Icon(Icons.chevron_right)),
        ])))),
      ]),
    );
  }
}

// 两端各补一张对应图片，滑动结束后归位，避免循环时跨过中间图片。
Widget _loopingPages({required PageController controller, required int count, required ValueChanged<int> onChanged, required IndexedWidgetBuilder itemBuilder, ScrollPhysics? physics}) {
  final looping = count > 1;
  return NotificationListener<ScrollEndNotification>(
    onNotification: (notification) {
      if (notification.depth == 0 && looping) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!controller.hasClients) return;
          final page = controller.page?.round();
          if (page == 0) controller.jumpToPage(count);
          if (page == count + 1) controller.jumpToPage(1);
        });
      }
      return false;
    },
    child: PageView.builder(controller: controller, physics: physics, itemCount: looping ? count + 2 : count, onPageChanged: (i) => onChanged(looping ? (i - 1) % count : i), itemBuilder: (context, i) => itemBuilder(context, looping ? (i - 1) % count : i)),
  );
}

/// 统一由缩放手势处理图片操作，避免与 PageView 争抢单指、双指手势。
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({super.key, required this.store, required this.asset, required this.onSwipe});
  final StudioStore store;
  final ImageAsset asset;
  final ValueChanged<bool> onSwipe;
  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}
class _ZoomableImageState extends State<_ZoomableImage> {
  final _transform = TransformationController();
  Offset _drag = Offset.zero;
  Offset _doubleTapPosition = Offset.zero;
  bool _swiping = false;
  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;
  @override
  void dispose() { _transform.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
    onDoubleTap: () {
      _transform.value = _zoomed ? Matrix4.identity() : (Matrix4.identity()
        ..translateByDouble(-_doubleTapPosition.dx * 2, -_doubleTapPosition.dy * 2, 0, 1)
        ..scaleByDouble(3, 3, 1, 1));
    },
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 8,
      onInteractionStart: (details) {
        _drag = Offset.zero;
        _swiping = !_zoomed && details.pointerCount == 1;
      },
      onInteractionUpdate: (details) {
        if (details.pointerCount != 1 || _zoomed) _swiping = false;
        if (_swiping) _drag += details.focalPointDelta;
      },
      onInteractionEnd: (details) {
        if (_swiping && _drag.dx.abs() > _drag.dy.abs() &&
            (_drag.dx.abs() > 60 || (_drag.dx.abs() > 20 && details.velocity.pixelsPerSecond.dx.abs() > 500))) {
          widget.onSwipe(_drag.dx < 0);
        }
        if (!_zoomed) _transform.value = Matrix4.identity();
        _swiping = false;
      },
      child: SizedBox.expand(child: assetImage(widget.store, widget.asset, full: true)),
    ),
  );
}
Widget assetImage(StudioStore store, ImageAsset asset, {bool full = false}) =>
    StudioImage(store: store, asset: asset, cacheWidth: full ? null : 640);
