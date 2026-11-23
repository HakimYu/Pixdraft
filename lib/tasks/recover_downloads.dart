import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';

import '../api/network_dio.dart';
import '../api/params.dart';
import '../data/studio_store.dart';
import '../models/models.dart';
import 'image_download.dart';

Future<int> retrySavedDownloads(StudioStore store, String taskId, {Dio? downloader}) async {
  final dio = downloader ?? createNetworkDio(BaseOptions(connectTimeout: const Duration(seconds: 30), receiveTimeout: const Duration(seconds: 120)));
  var recovered = 0;
  try {
    final entries = await store.db.query('settings', where: 'key LIKE ?', whereArgs: ['pending:%']);
    for (final row in entries) {
      final value = Map<String, dynamic>.from(jsonDecode(row['value'] as String) as Map);
      if (value['taskId'] != taskId) continue;
      final task = await store.task(taskId);
      if (task == null || task.status == TaskStatus.running || task.status == TaskStatus.queued) throw StateError('请先停止任务再重新下载');
      final bytes = await downloadImage(value['url'] as String, downloader: dio);
      final asset = await store.saveAsset(bytes, value['mime'] as String, remoteUrl: value['url'] as String);
      await store.db.transaction((tx) async {
        final tasks = await tx.query('tasks', where: 'id = ?', whereArgs: [taskId]);
        if (tasks.isEmpty || ['running', 'queued'].contains(tasks.single['status']) || tasks.single['attempt'] != task.attempt) throw StateError('任务状态已变化，请重新操作');
        await tx.insert('task_assets', {'task_id': taskId, 'asset_id': asset.id, 'role': 'output', 'position': value['position'], 'attempt': value['attempt']}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.delete('settings', where: 'key = ?', whereArgs: [row['key']]);
        if (value['attempt'] == task.attempt) {
          final count = Sqflite.firstIntValue(await tx.rawQuery("SELECT COUNT(*) FROM task_assets WHERE task_id = ? AND role = 'output' AND attempt = ?", [taskId, task.attempt])) ?? 0;
          final provider = task.input.provider;
          final expectedCount = provider.protocol.isAsync
              ? task.input.params.count.clamp(1, 10)
              : resolveParams(task.input.params, protocol: provider.protocol, imageModel: provider.protocol == ApiProtocol.responses ? provider.toolModel : provider.imageModel, hasInputImages: task.input.references.isNotEmpty).count;
          await tx.update('tasks', {'status': count >= expectedCount ? 'done' : 'partialError', 'error': count >= expectedCount ? null : '已保存 $count/$expectedCount 张'}, where: 'id = ?', whereArgs: [taskId]);
        }
      });
      recovered++;
      store.refresh();
    }
    return recovered;
  } finally {
    if (downloader == null) dio.close();
  }
}
