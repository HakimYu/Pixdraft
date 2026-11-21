import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../data/studio_store.dart';
import '../models/models.dart';
import 'background_worker.dart';

class BackgroundStartResult {
  const BackgroundStartResult.started() : message = null;
  const BackgroundStartResult.failed(this.message);
  final String? message;
  bool get started => message == null;
}

class BackgroundTasks {
  BackgroundTasks._();
  static const serviceId = 7411;
  static const drainCommand = 'drain';
  static const cancelCommand = 'cancel';
  static const cancelButtonId = 'cancel_active_task';
  static final _changes = StreamController<void>.broadcast();
  static final _acknowledged = <String>{};
  static final previews = <String, Uint8List>{};
  static bool _initialized = false;
  static bool get _usesService => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static final _process = Expando<BackgroundTaskHandler>();
  static Stream<void> get changes => _changes.stream;

  static Future<void> init() async {
    if (!_usesService || _initialized) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // 通知渠道的重要性创建后无法调低，换 id 才能让已装机的用户也变成静音折叠。
        channelId: 'image_generation_silent', channelName: '图片生成',
        channelDescription: '在后台执行图片生成任务',
        // 生成中只留一条静音折叠的通知，这是 Android 对前台服务的强制要求。
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN, onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(2000),
        autoRunOnBoot: false, autoRunOnMyPackageReplaced: false,
        allowAutoRestart: false, allowWakeLock: true, stopWithTask: false,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _initialized = true;
  }

  /// 等到后台实际接收排空命令；插件的 running 标志早于 Dart 通道就绪。
  static Future<BackgroundStartResult> start({StudioStore? store}) async {
    if (!_usesService) {
      if (store == null) return const BackgroundStartResult.failed('本地工作台未打开');
      final handler = _process[store] ??= BackgroundTaskHandler.inProcess(store, (values) {
        previews..clear()..addAll(values);
        _changes.add(null);
      });
      try {
        await handler.startInProcess();
      } on Object catch (_) {
        return const BackgroundStartResult.failed('应用内执行未能启动，请重试排队任务');
      }
      return const BackgroundStartResult.started();
    }
    final requestId = newId();
    try {
      await init();
      await _requestNotificationPermission();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      do {
        if (!await FlutterForegroundTask.isRunningService) {
          final result = await FlutterForegroundTask.startService(
            serviceId: serviceId,
            serviceTypes: const [ForegroundServiceTypes.dataSync],
            notificationTitle: '图片生成进行中',
            notificationIcon: const NotificationIcon(
              metaDataName: 'com.dinosaur.imagegen.generation_running_icon',
              largeIconMetaDataName: 'com.dinosaur.imagegen.generation_running_large_icon',
            ),
            notificationText: '任务正在后台执行，点击返回应用',
            notificationButtons: const [NotificationButton(id: cancelButtonId, text: '取消全部任务')],
            callback: backgroundTaskCallback,
          );
          if (result is ServiceRequestFailure && result.error is! ServiceAlreadyStartedException) {
            return BackgroundStartResult.failed(_describeStartError(result.error));
          }
        }
        FlutterForegroundTask.sendDataToTask({'command': drainCommand, 'requestId': requestId});
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (_acknowledged.remove(requestId)) return const BackgroundStartResult.started();
      } while (DateTime.now().isBefore(deadline));
      return const BackgroundStartResult.failed('后台通道未就绪，请在作品页重试此任务');
    } on Object catch (error) {
      return BackgroundStartResult.failed(_describeStartError(error));
    } finally {
      _acknowledged.remove(requestId);
    }
  }

  static Future<void> cancel({String? taskId, StudioStore? store}) async {
    final process = !_usesService && store != null ? _process[store] : null;
    if (process != null) {
      await process.cancelInProcess(taskId);
      return;
    }
    try {
      if (_usesService && await FlutterForegroundTask.isRunningService) {
        FlutterForegroundTask.sendDataToTask({'command': cancelCommand, 'taskId': ?taskId});
        return;
      }
    } on Object catch (_) {
      // 服务不可达时将指定任务恢复成可重试状态。
    }
    if (taskId != null && store != null) {
      await store.transition(taskId, TaskStatus.running, TaskStatus.interrupted, error: '后台服务已停止，任务可能已在服务端执行，请确认后重试');
      await store.transition(taskId, TaskStatus.queued, TaskStatus.aborted);
    }
  }

  static Future<void> recoverInProcess(StudioStore store) async {
    if (!_usesService) await store.recoverInterrupted();
  }

  static Future<void> resumeQueue(StudioStore store) async {
    if (_usesService && await FlutterForegroundTask.isRunningService) return;
    final pending = await store.db.query('tasks', columns: ['id'],
        where: "deleted_at IS NULL AND status IN ('queued', 'running')", limit: 1);
    if (pending.isNotEmpty) {
      await start(store: store);
    }
  }

  static Future<bool> recoverStaleTasks(StudioStore store) async {
    if (_usesService && await FlutterForegroundTask.isRunningService) return false;
    await store.recoverInterrupted();
    return true;
  }

  static void _onTaskData(Object data) {
    if (data is Map && data['ack'] is String) {
      _acknowledged.add(data['ack'] as String);
      return;
    }
    if (data is Map && data['previews'] is Map) {
      previews.clear();
      for (final entry in (data['previews'] as Map).entries) {
        if (entry.key is String && entry.value is String) {
          try { previews[entry.key as String] = base64Decode(entry.value as String); } on FormatException catch (_) { /* 临时预览可丢弃。 */ }
        }
      }
    }
    _changes.add(null);
  }

  static Future<void> _requestNotificationPermission() async {
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } on Object catch (_) {
      // 通知被拒绝仍可执行前台服务。
    }
  }

  static String _describeStartError(Object error) => switch (error) {
    ServiceTimeoutException() => '后台服务启动超时，请在作品页重试此任务',
    ServiceNotInitializedException() => '后台服务未初始化，请在作品页重试此任务',
    PlatformException(:final code) => '后台服务启动失败（$code），请在作品页重试此任务',
    _ => '后台服务启动失败，请在作品页重试此任务',
  };
}
