import 'package:flutter/material.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';

class PromptLibraryPage extends StatefulWidget {
  const PromptLibraryPage({super.key, required this.store, this.current = ''});
  final StudioStore store;
  final String current;
  @override
  State<PromptLibraryPage> createState() => _PromptLibraryPageState();
}

class _PromptLibraryPageState extends State<PromptLibraryPage> {
  List<Map<String, Object?>> _prompts = [];
  String _search = '';
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prompts = await widget.store.prompts();
      if (mounted)
        setState(() {
          _prompts = prompts;
          _error = null;
        });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取提示词，请重试');
    }
  }

  Future<void> _edit({
    Map<String, Object?>? prompt,
    String content = '',
  }) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _PromptEditor(
          store: widget.store,
          prompt: prompt,
          content: content,
        ),
      ),
    );
    await _load();
  }

  Future<void> _delete(Map<String, Object?> prompt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除提示词？'),
        content: Text(prompt['title'] as String),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.store.deletePrompt(prompt['id'] as String);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = '删除失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _prompts.where(
      (p) => '${p['title']} ${p['content']}'.toLowerCase().contains(
        _search.toLowerCase(),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('提示词库'),
        actions: [
          IconButton(
            tooltip: '新增提示词',
            onPressed: _edit,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: '搜索标题或内容',
              ),
            ),
          ),
          if (widget.current.trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('保存当前提示词'),
              onTap: () => _edit(content: widget.current),
            ),
          if (_error != null)
            ListTile(
              title: Text(_error!),
              trailing: TextButton(onPressed: _load, child: const Text('重试')),
            ),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('没有匹配的提示词'))
                : ListView(
                    children: [
                      for (final p in visible)
                        ListTile(
                          title: Text(
                            p['title'] as String,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            p['content'] as String,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () =>
                              Navigator.pop(context, p['content'] as String),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'edit') {
                                _edit(prompt: p);
                              } else {
                                _delete(p);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _PromptEditor extends StatefulWidget {
  const _PromptEditor({
    required this.store,
    this.prompt,
    required this.content,
  });
  final StudioStore store;
  final Map<String, Object?>? prompt;
  final String content;
  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final _title = TextEditingController(
    text: widget.prompt?['title'] as String? ?? '',
  );
  late final _content = TextEditingController(
    text: widget.prompt?['content'] as String? ?? widget.content,
  );
  bool _saving = false;
  String? _error;
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.store.savePrompt(
        widget.prompt?['id'] as String? ?? newId(),
        _title.text.trim().isEmpty
            ? _content.text.split('\n').first
            : _title.text,
        _content.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = '保存失败，请填写内容并检查存储空间';
        });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.prompt == null ? '新增提示词' : '编辑提示词')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: '标题（可选）'),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _content,
          minLines: 8,
          maxLines: 20,
          decoration: const InputDecoration(
            labelText: '提示词内容',
            alignLabelWithHint: true,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存' : '保存'),
        ),
      ],
    ),
  );
}
