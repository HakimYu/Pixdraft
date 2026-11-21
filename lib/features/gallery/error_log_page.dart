import 'package:flutter/material.dart';
import 'error_details.dart';

import '../../data/studio_store.dart';

class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key, required this.store});
  final StudioStore store;
  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  late Future<List<Map<String, Object?>>> _loading = _load();
  Future<List<Map<String, Object?>>> _load() => widget.store.db.query('errors', orderBy: 'created_at DESC', limit: 200);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('错误记录'), actions: [IconButton(tooltip: '刷新', onPressed: () => setState(() => _loading = _load()), icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<Map<String, Object?>>>(future: _loading, builder: (context, snapshot) {
      if (snapshot.hasError) return Center(child: TextButton(onPressed: () => setState(() => _loading = _load()), child: const Text('读取失败，点击重试')));
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
      final rows = snapshot.data!;
      return rows.isEmpty ? const Center(child: Text('最近 15 天没有错误记录')) : ListView(padding: const EdgeInsets.all(16), children: [
        const Text('显示最近 200 条记录，保留 15 天。'),
        const SizedBox(height: 16),
        for (final row in rows) Padding(padding: const EdgeInsets.only(bottom: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ErrorDetails(message: row['message'] as String),
          const SizedBox(height: 8),
          Text('${row['created_at']}\n任务 ${row['task_id']}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          const Divider(height: 1),
        ])),
      ]);
    }),
  );
}
