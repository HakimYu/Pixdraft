import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:sqflite/sqflite.dart';

import '../api/openai_client.dart';
import '../data/studio_store.dart';
import '../models/models.dart';
import '../plugins/plugin_manifest.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_registry.dart';
import '../tasks/task_runner.dart';
import 'background_tasks.dart';
import 'completion_notes.dart';

/// 服务入口：插件通过 callback handle 在独立 Flutter engine 中执行它。
@pragma('vm:entry-point')
void backgroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundTaskHandler());
}

/// 前台服务内的任务处理器：只负责调度，任务状态一律落库。
class BackgroundTaskHandler extends TaskHandler {
  BackgroundTaskHandler() : _processChanges = null;
  BackgroundTaskHandler.inProcess(StudioStore store, this._processChanges)
    : _store = store;

  final void Function(Map<String, Uint8List>)? _processChanges;
  Future<void>? _preparingProcess;

  Future<void> startInProcess() async {
    final pending = _preparingProcess ??= _prepareInProcess();
    try {
      await pending;
    } finally {
      if (identical(_preparingProcess, pending)) _preparingProcess = null;
    }
    unawaited(_drain());
  }

  Future<void> _prepareInProcess() async {
    final store = _store!;
    if (_runner != null) {
      await _refreshPlugins(store);
      return;
    }
    _pluginStamp = await _stamp(store);
    _runner = await _buildRunner(store)..addListener(_notifyUi);
  }

  Future<void> cancelInProcess(String? taskId) => _cancel(taskId);

  @visibleForTesting
  BackgroundTaskHandler.forTesting(
    StudioStore store,
    TaskRunner runner, {
    Future<void> Function(int done, int failed)? finished,
  }) : _store = store,
       _runner = runner,
       _processChanges = null {
    // 注入的测试 runner 也要推通知，否则标题和按钮状态永远不更新。
    runner.addListener(_notifyUi);
    if (finished != null) _finished = finished;
  }
  StudioStore? _store;
  TaskRunner? _runner;
  String? _pluginStamp;
  int _drains = 0;
  int? _notificationCount;
  bool _stopping = false;
  bool _checkingIdle = false;
  bool _flushed = false;
  Future<void> Function(int done, int failed) _finished = _sendFinished;

  static Future<void> _sendFinished(int done, int failed) =>
      CompletionNotes.away(done: done, failed: failed);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final StudioStore store;
    try {
      store = _store ?? await StudioStore.open();
      if (_store == null) await store.recoverInterrupted();
    } catch (error) {
      // 打不开数据库时直接停服务，避免留下一个永远处理不了任务的常驻通知。
      debugPrint('后台任务初始化失败: $error');
      unawaited(FlutterForegroundTask.stopService());
      return;
    }
    _store = store;
    final runner = _runner ?? await _buildRunner(store);
    if (!identical(runner, _runner)) {
      // runner 每次状态变化都通知 UI 重新查询，后台不维护第二份任务状态。
      runner.addListener(_notifyUi);
      _runner = runner;
    }
    // 注入的 runner 也要记下插件戳，否则第一条 drain 命令就会误判插件变动。
    _pluginStamp ??= await _stamp(store);
    _flushed = false;
    // 注入的测试 runner 同样要跑，否则后台不会处理已有排队任务。
    await _drain();
  }

  Future<TaskRunner> _buildRunner(StudioStore store) async {
    final client = await _client(store);
    return TaskRunner(
      store,
      client,
      plugins: client is PluginRegistry ? client : null,
    );
  }

  /// 插件运行时接管供应商调用；加载失败只让未知适配器失败，绝不回退成按 images 收费。
  Future<GenerationClient> _client(StudioStore store) async {
    try {
      final registry = await PluginRegistry.load(store);
      if (registry.issues.isNotEmpty)
        debugPrint('插件注册问题：${registry.issues.join('；')}');
      return registry;
    } catch (error) {
      debugPrint('插件运行时加载失败，仅旧内置任务可继续: $error');
      return _LegacyClient(store);
    }
  }

  Future<String> _stamp(StudioStore store) async =>
      jsonEncode((await store.setting(pluginIndexKey))?['plugins'] ?? const {});

  /// 安装/启停插件后换用新注册表实例，但绝不打断正在执行的任务。
  Future<void> _refreshPlugins(StudioStore store) async {
    final runner = _runner;
    if (runner == null || runner.activeTaskIds.isNotEmpty || _drains != 0)
      return;
    final stamp = await _stamp(store);
    if (stamp == _pluginStamp) return;
    final next = await _buildRunner(store);
    if (!identical(_runner, runner) || _stopping || _drains != 0 ||
        runner.activeTaskIds.isNotEmpty) {
      final unused = next.client;
      if (unused is PluginRegistry) unawaited(unused.dispose());
      next.dispose();
      return;
    }
    final previous = runner.client;
    runner.removeListener(_notifyUi);
    next.addListener(_notifyUi);
    _runner = next;
    _pluginStamp = stamp;
    runner.dispose();
    if (previous is PluginRegistry) unawaited(previous.dispose());
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final command = data['command'];
    if (command == BackgroundTasks.drainCommand) {
      final store = _store;
      if (_stopping || _runner == null || store == null) return;
      unawaited(_refreshPlugins(store).then((_) => _drain()));
      if (data['requestId'] is String)
        FlutterForegroundTask.sendDataToMain({'ack': data['requestId']});
    } else if (command == BackgroundTasks.cancelCommand) {
      unawaited(_cancel(data['taskId'] as String?));
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == BackgroundTasks.cancelButtonId) unawaited(_cancel(null));
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_drains == 0 && !_stopping) unawaited(_drain());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _runner?.removeListener(_notifyUi);
    // 故意不 close store：sqflite 在进程内按路径共享数据库句柄，这里关闭会连带
    // 打断 UI isolate 的读写；引用随 engine 一起释放即可。
    _runner = null;
    _store = null;
  }

  /// 每次提交都立即调度；等待中的 drain 不阻塞后来提交的任务。
  Future<void> _drain() async {
    final runner = _runner;
    if (runner == null || _stopping) return;
    _drains++;
    try {
      await runner.drain();
    } on Object catch (error) {
      debugPrint('后台任务执行异常: $error');
    } finally {
      _drains--;
    }
    if (_processChanges == null) await _stopWhenIdle();
  }

  /// 队列排空后自行停止服务，避免长期占用通知和唤醒锁。
  Future<void> _stopWhenIdle() async {
    if (_checkingIdle || _stopping) return;
    _checkingIdle = true;
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      final store = _store;
      final runner = _runner;
      if (_drains != 0 || store == null || runner == null) return;
      final tasks = await store.db.query(
        'tasks',
        columns: ['status', 'deleted_at'],
        where: "status IN ('queued', 'running')",
      );
      if (_drains != 0 || runner.activeTaskIds.isNotEmpty) return;
      if (tasks.any(
        (task) => task['deleted_at'] == null && task['status'] == 'queued',
      )) {
        unawaited(_drain());
        return;
      }
      if (tasks.any((task) => task['status'] == 'running')) return;
      // 从此刻开始拒绝确认新 drain；UI 会等服务停下后重新启动并握手。
      _stopping = true;
      if (!_flushed) {
        _flushed = true;
        // 必须在停服前 await，引擎销毁会中断未完成的 Dart 任务。
        await _flushFinished();
      }
      final result = await FlutterForegroundTask.stopService();
      if (result is ServiceRequestFailure) _stopping = false;
    } finally {
      _checkingIdle = false;
    }
  }

  /// 每次服务排空只汇报一次：应用不在前台时由完成提醒发出通知。
  Future<void> _flushFinished() async {
    final store = _store;
    if (store == null) return;
    try {
      var done = 0;
      final failedTasks = <String>{};
      for (final (id, attempt) in _runner!.startedAttempts) {
        done +=
            Sqflite.firstIntValue(
              await store.db.rawQuery(
                "SELECT COUNT(*) FROM task_assets WHERE task_id = ? AND attempt = ? AND role = 'output'",
                [id, attempt],
              ),
            ) ??
            0;
        final tasks = await store.db.query(
          'tasks',
          columns: ['status', 'attempt'],
          where: 'id = ?',
          whereArgs: [id],
        );
        if (tasks.isNotEmpty &&
            tasks.single['attempt'] == attempt &&
            ['error', 'partialError'].contains(tasks.single['status']))
          failedTasks.add(id);
      }
      if (done + failedTasks.length > 0)
        await _finished(done, failedTasks.length);
    } on Object catch (error) {
      debugPrint('完成提醒失败: $error');
    }
  }

  /// 通知取消本次查询到的全部任务，卡片按钮只取消指定任务。
  Future<void> _cancel(String? taskId) async {
    final store = _store;
    final runner = _runner;
    if (store == null || runner == null) return;
    final targets = taskId == null
        ? (await store.db.query(
            'tasks',
            columns: ['id'],
            where: "status IN ('running', 'queued')",
          )).map((t) => t['id'] as String).toList()
        : [taskId];
    await Future.wait(targets.map(runner.cancel));
  }

  void _notifyUi() {
    final changes = _processChanges;
    if (changes != null) {
      changes(_runner?.previews ?? const {});
      return;
    }
    final count = _runner?.activeTaskIds.length ?? 0;
    if (!_stopping && count != _notificationCount) {
      _notificationCount = count;
      unawaited(
        FlutterForegroundTask.updateService(
          notificationTitle: count > 0 ? '正在生成 $count 个任务' : '图片生成已结束',
          notificationText: count > 0 ? '可返回应用单独停止任务' : '正在确认任务队列',
          notificationButtons: const [
            NotificationButton(
              id: BackgroundTasks.cancelButtonId,
              text: '取消全部任务',
            ),
          ],
        ),
      );
    }
    // UI isolate 不在时 sendDataToMain 是空操作。
    FlutterForegroundTask.sendDataToMain({
      'type': 'changed',
      'previews':
          _runner?.previews.map(
            (id, bytes) => MapEntry(id, base64Encode(bytes)),
          ) ??
          <String, String>{},
    });
  }
}

/// 插件运行时不可用时的兜底客户端：只允许真正的旧内置任务。
class _LegacyClient implements GenerationClient {
  _LegacyClient(this.store);
  final StudioStore store;
  late final OpenAiClient _client = OpenAiClient(readAsset: store.readAsset, assetLength: store.assetLength);
  static const _builtIn = {'images', 'responses', 'wavespeed', 'evolink'};

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) {
    // 缺版本或未知 adapterId 一律失败：按旧协议猜端点会打错供应商并产生费用。
    if (!_builtIn.contains(input.provider.adapterId) ||
        input.provider.adapterVersion != null) {
      return Stream.error(
        PluginException('插件运行时未加载，无法执行适配器「${input.provider.adapterId}」'),
      );
    }
    return _client.generate(input, apiKey);
  }

  @override
  void cancel(String taskId) => _client.cancel(taskId);
}
