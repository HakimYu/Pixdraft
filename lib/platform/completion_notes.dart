import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 生成完成提醒：只在本机不在前台时发出，点开回到应用。
class CompletionNotes {
  CompletionNotes._();

  /// 当前只有 Android 后台工作器和完成提醒通道。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const channelId = 'image_generation_done';
  static const _id = 1001;
  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<bool?>? _ready;

  static Future<void> away({required int done, required int failed}) async {
    if (!isSupported || await _inForeground()) return;
    try {
      // 后台 isolate 里首次用到时再初始化，主 isolate 不需要这条通道。
      await (_ready ??= _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_generation_done'),
        ),
      ));
      await _plugin.show(
        id: _id,
        title: '生图完成',
        body: _body(done, failed),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            '生成完成',
            channelDescription: '图片生成完成的提醒',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            largeIcon: DrawableResourceAndroidBitmap('ic_generation_done_large'),
          ),
        ),
      );
    } on Object catch (error) {
      debugPrint('完成通知发送失败: $error');
    }
  }

  /// 判断不出来时按“在前台”处理，宁可不提醒也不要误打扰。
  static Future<bool> _inForeground() async {
    try {
      return await FlutterForegroundTask.isAppOnForeground;
    } on Object catch (_) {
      return true;
    }
  }

  static String _body(int done, int failed) => switch ((done, failed)) {
    (final done, 0) => '已保存 $done 张图片',
    (0, final failed) => '$failed 个任务失败',
    (final done, final failed) => '已保存 $done 张图片，$failed 个任务失败',
  };
}
