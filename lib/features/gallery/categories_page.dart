import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key, required this.store});
  final StudioStore store;

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<Map<String, Object?>> _categories = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_load);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.store.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final categories = await widget.store.categories();
      if (mounted) setState(() { _categories = categories; _loading = false; _error = null; });
    } catch (_) {
      if (mounted) setState(() { _error = '读取分类失败，请重试'; _loading = false; });
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请重试');
    }
  }

  Future<void> _edit([Map<String, Object?>? category]) async {
    final controller = TextEditingController(text: category?['name'] as String? ?? '');
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(category == null ? '新建分类' : '重命名分类'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: '分类名称')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('保存')),
      ],
    ));
    // 对话框退场动画结束后再释放输入框控制器。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    await _act(() => widget.store.saveCategory(category?['id'] as String? ?? newId(), name));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('分类管理')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(children: [
      ListTile(leading: const Icon(Icons.add), title: const Text('新建分类'), onTap: _edit),
      if (_error != null) ListTile(title: Text(_error!), trailing: TextButton(onPressed: _load, child: const Text('重试'))),
      if (_categories.isEmpty && _error == null) const Padding(padding: EdgeInsets.all(24), child: Text('还没有分类，新建后可在作品页为作品设置分类')),
      for (final category in _categories) ListTile(
        title: Text(category['name'] as String),
        onTap: () => _edit(category),
        trailing: IconButton(tooltip: '删除分类（保留作品）', icon: const Icon(Icons.delete_outline), onPressed: () => _act(() => widget.store.deleteCategory(category['id'] as String))),
      ),
    ]),
  );
}
