import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'data/studio_store.dart';
import 'features/backup/backup_page.dart';
import 'features/backup/backup_service.dart';
import 'features/create/create_page.dart';
import 'features/plugins/plugin_tools_page.dart';
import 'features/plugins/plugins_page.dart';
import 'features/gallery/error_log_page.dart';
import 'features/gallery/categories_page.dart';
import 'features/providers/providers_page.dart';
import 'models/models.dart';
import 'plugins/plugin_registry.dart';
import 'platform/background_tasks.dart';
import 'platform/web_session.dart';

class _WebSessionUnavailable implements Exception {
  const _WebSessionUnavailable(this.message);
  final String message;
}
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ImageStudioApp());
}

class ImageStudioApp extends StatefulWidget {
  const ImageStudioApp({super.key, this.store});
  final StudioStore? store;
  @override
  State<ImageStudioApp> createState() => _ImageStudioAppState();
}

class _ImageStudioAppState extends State<ImageStudioApp> {
  late Future<StudioStore> _opening;
  ThemeMode _theme = ThemeMode.system;
  @override
  void initState() {
    super.initState();
    _opening = _open();
  }

  Future<StudioStore> _open() async {
    if (kIsWeb && widget.store == null) {
      final message = await acquireWebSession();
      if (message != null) throw _WebSessionUnavailable(message);
    }
    final store = widget.store ?? await StudioStore.open();
    if (widget.store == null) {
      await BackgroundTasks.init();
      await BackgroundTasks.recoverInProcess(store);
      if (!kIsWeb) await BackupService(store).recoverInterruptedImports();
      await store.pruneExpired();
    }
    final settings = await store.setting('appearance');
    if (mounted)
      setState(
        () => _theme =
            ThemeMode.values
                .where((m) => m.name == settings?['theme'])
                .firstOrNull ??
            ThemeMode.system,
      );
    if (widget.store == null) await BackgroundTasks.resumeQueue(store);
    return store;
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pixdraft',
    debugShowCheckedModeBanner: false,
    theme: _themeData(Brightness.light),
    darkTheme: _themeData(Brightness.dark),
    themeMode: _theme,
    home: FutureBuilder<StudioStore>(
      future: _opening,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(switch (snapshot.error) {
                      _WebSessionUnavailable(:final message) => message,
                      _ when kIsWeb => '无法打开浏览器本地存储，请检查站点存储权限或可用空间',
                      _ => '无法打开本地工作台，请检查存储空间后重试',
                    }, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() => _opening = _open()),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          );
        if (!snapshot.hasData)
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        return StudioHome(
          store: snapshot.data!,
          theme: _theme,
          onTheme: (theme) async {
            await snapshot.data!.saveSetting('appearance', {
              'theme': theme.name,
            });
            if (mounted) setState(() => _theme = theme);
          },
        );
      },
    ),
  );
  ThemeData _themeData(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff3b82f6),
          brightness: brightness,
        ).copyWith(
          primary: const Color(0xff3b82f6),
          onPrimary: Colors.white,
          surface: dark ? const Color(0xff111827) : Colors.white,
        );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );
    return base.copyWith(
      scaffoldBackgroundColor: dark
          ? const Color(0xff030712)
          : const Color(0xfff9fafb),
      dividerColor: dark ? const Color(0xff374151) : const Color(0xffe5e7eb),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge!.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: dark ? const Color(0xff374151) : const Color(0xffe5e7eb),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xff111827) : const Color(0xfff9fafb),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: dark ? const Color(0xff374151) : const Color(0xffe5e7eb),
          ),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: dark ? const Color(0xff374151) : const Color(0xffe5e7eb),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    );
  }
}

class StudioHome extends StatefulWidget {
  const StudioHome({
    super.key,
    required this.store,
    required this.theme,
    required this.onTheme,
  });
  final StudioStore store;
  final ThemeMode theme;
  final ValueChanged<ThemeMode> onTheme;
  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> with WidgetsBindingObserver {
  StreamSubscription<void>? _changes;
  PluginRegistry? _registry;
  Future<PluginRegistry>? _loadingPlugins;

  /// 插件运行时按需加载；失败不缓存，下次操作可以重试。
  Future<PluginRegistry> _plugins() async {
    final ready = _registry;
    if (ready != null) return ready;
    final pending = _loadingPlugins;
    if (pending != null) return pending;
    final future = PluginRegistry.load(widget.store);
    _loadingPlugins = future;
    try {
      final registry = await future;
      if (mounted) setState(() => _registry = registry);
      return registry;
    } finally {
      _loadingPlugins = null;
    }
  }

  /// 安装或启停插件后重建运行时；已在后台执行的任务仍用原注册表实例。
  Future<void> _reloadPlugins() async {
    final previous = _registry;
    _registry = null;
    if (previous != null) await previous.dispose();
    if (!mounted) return;
    try {
      await _plugins();
    } on Object catch (_) {
      // 插件暂时加载不了，下次操作会重试。
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = BackgroundTasks.changes.listen((_) => widget.store.refresh());
    unawaited(_plugins().then<void>((_) {}).catchError((Object _) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_changes?.cancel());
    unawaited(_registry?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.store.refresh();
  }

  void _providers() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => ProvidersPage(store: widget.store)),
  );
  Future<void> _start() async {
    final result = await BackgroundTasks.start(store: widget.store);
    if (!result.started) throw StateError(result.message!);
  }

  Future<void> _startTask(String id) async {
    try {
      await _start();
    } catch (_) {
      if (await widget.store.transition(
        id,
        TaskStatus.queued,
        TaskStatus.interrupted,
        error: '后台执行未能启动，请在作品页重试此任务',
      )) {
        throw StateError('后台执行未能启动，任务已保留在作品页，请从该任务重试');
      }
      // 已被服务认领的任务仍继续执行，避免用户误以为未提交而重复生成。
    }
  }

  Future<void> _submit(GenerationInput input) async {
    if (input.prompt.trim().isEmpty && input.references.isEmpty)
      throw const FormatException('请输入提示词或选择参考图片');
    final plugins = await _plugins();
    final plan = await plugins.plan(await plugins.pinInput(input));
    if (plan.expectedCount < 1)
      throw const FormatException('生成数量需为 1–10，参考图片最多 16 张');
    final providers = await widget.store.providers();
    if (!providers.any((p) => p.id == plan.input.provider.id && p.enabled))
      throw StateError('供应商已删除或停用');
    await widget.store.enqueue(plan.input);
    await _startTask(plan.input.taskId);
  }

  Future<void> _cancel(String id) async {
    // 先条件取消 queued，防止后台抢到同一任务后 UI 无条件覆盖其状态。
    if (!await widget.store.transition(
      id,
      TaskStatus.queued,
      TaskStatus.aborted,
    ))
      await BackgroundTasks.cancel(taskId: id, store: widget.store);
  }

  @override
  Widget build(BuildContext context) => CreatePage(
    store: widget.store,
    submit: _submit,
    retry: (id) async {
      await widget.store.retryTask(id);
      await _startTask(id);
    },
    resumeRemote: (id) async {
      await widget.store.resumeRemoteTask(id);
      await _startTask(id);
    },
    cancel: _cancel,
    openProviders: _providers,
    openSettings: _settings,
    plugins: _registry,
  );

  void _settings() {
    var selectedTheme = widget.theme;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          builder: (context, update) => Scaffold(
            appBar: AppBar(title: const Text('设置')),
            body: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.hub_outlined),
                  title: const Text('供应商与模型'),
                  subtitle: const Text('连接服务、管理密钥和请求选项'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _providers,
                ),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('分类管理'),
                  subtitle: const Text('新建、重命名与删除作品分类'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CategoriesPage(store: widget.store),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('备份与恢复'),
                  subtitle: const Text('导出本地数据、从备份恢复工作台'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => BackupPage(store: widget.store),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: const Text('错误记录'),
                  subtitle: const Text('最近 15 天的生成错误'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ErrorLogPage(store: widget.store),
                    ),
                  ),
                ),
                if (!kIsWeb) ListTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('插件'),
                  subtitle: const Text('安装本地扩展，启用或停用供应商适配器'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PluginsPage(
                          store: widget.store,
                          manager: _registry?.manager,
                        ),
                      ),
                    );
                    await _reloadPlugins();
                  },
                ),
                if (!kIsWeb) ListTile(
                  leading: const Icon(Icons.handyman_outlined),
                  title: const Text('图片工具'),
                  subtitle: const Text('用插件在本地处理已有图片'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PluginToolsPage(store: widget.store),
                    ),
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<ThemeMode>(
                    key: ValueKey(selectedTheme),
                    initialValue: selectedTheme,
                    decoration: const InputDecoration(labelText: '外观'),
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('跟随系统'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('浅色'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('深色'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        widget.onTheme(v);
                        update(() => selectedTheme = v);
                      }
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: const Text('继续处理排队任务'),
                  subtitle: const Text(kIsWeb ? '请在任务完成前保持此标签页打开' : '任务执行未启动时可从这里重试'),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final result = await BackgroundTasks.start(store: widget.store);
                    messenger.showSnackBar(
                      SnackBar(content: Text(result.message ?? '后台执行已启动')),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('关于 Pixdraft'),
                  subtitle: const Text('本地图片创作工作台 · 1.0.0'),
                  onTap: () => showAboutDialog(
                    context: context,
                    applicationName: 'Pixdraft',
                    applicationVersion: '1.0.0',
                    children: [
                      const Text(
                        kIsWeb
                            ? '数据和密钥保存在当前浏览器的站点存储。生成请求直接发给你配置的供应商；服务需允许跨域请求。关闭标签页会中断执行。'
                            : '创作数据保存在本机，API 密钥保存在系统安全存储。生成请求发送给你配置的供应商。\n\n参考 GPT_Image_Playground（MIT）设计与协议。',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
