# flutter_foreground_task

本目录随项目附带 [flutter_foreground_task 11.0.3](https://pub.dev/packages/flutter_foreground_task/versions/11.0.3) 的运行时源码。上游许可见 [LICENSE](LICENSE)。

Pixdraft 需要在 Android 前台服务通知中显示大图标。本地补丁通过 `NotificationIcon.largeIconMetaDataName` 从 Android manifest 读取位图资源。升级时请保留该行为；上游支持配置通知大图标后，可改用上游依赖。
