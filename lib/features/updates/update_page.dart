import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updates.dart';

Future<String?> installedVersion() async {
  try {
    final version = (await PackageInfo.fromPlatform()).version;
    return version.isEmpty ? null : version;
  } on Exception {
    return null;
  }
}

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key, required this.updates, required this.version});

  final AppUpdates updates;
  final Future<String?> version;

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  UpdatePreferences? _preferences;
  bool _busy = false;
  bool _loadFailed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.updates.store.setting(updateSettingsKey);
      if (mounted) setState(() => _preferences = UpdatePreferences(data));
    } on Exception {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _save({
    bool? automaticCheck,
    UpdateSource? source,
    String? host,
  }) async {
    final previous = _preferences!;
    final data = <String, dynamic>{
      'automaticCheck': automaticCheck ?? previous.automaticCheck,
      'source': (source ?? previous.mode).name,
      'host': host ?? previous.host,
    };
    setState(() => _busy = true);
    try {
      await widget.updates.store.saveSetting(updateSettingsKey, data);
      if (mounted) {
        setState(() {
          _preferences = UpdatePreferences(data);
          _message = null;
        });
      }
    } on Exception {
      if (mounted) setState(() => _message = '无法保存更新设置，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseMirror() async {
    var cached = const <String>[];
    try {
      cached = await widget.updates.cachedMirrors();
    } on Exception {
      // 内置镜像仍可选。
    }
    if (!mounted) return;
    final host = await showDialog<String>(
      context: context,
      builder: (_) => _MirrorDialog(
        initialHost: _preferences?.host,
        hosts: {...builtInMirrors, ...cached}.toList(),
      ),
    );
    if (mounted && host != null) {
      await _save(source: UpdateSource.custom, host: host);
    }
  }

  Future<void> _check() async {
    final preferences = _preferences!;
    setState(() {
      _busy = true;
      _message = '正在检查更新…';
    });
    try {
      final version = await widget.version;
      if (!mounted) return;
      if (version == null) {
        setState(() => _message = '无法读取当前安装版本。');
        return;
      }
      final result = await widget.updates.check(version, preferences);
      if (!mounted) return;
      setState(
        () => _message = switch (result.status) {
          UpdateStatus.available => '发现新版 ${result.release!.tag}',
          UpdateStatus.current => '当前已是最新版本。',
          UpdateStatus.noRelease => 'GitHub 暂无正式发布版本。',
          UpdateStatus.unconfirmed => '暂时无法确认最新版本，请稍后重试。',
        },
      );
      if (result.release case final release?) {
        await showUpdate(
          context,
          widget.updates,
          version,
          release,
          preferences,
        );
      }
    } on Exception {
      if (mounted) setState(() => _message = '暂时无法确认最新版本，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = _preferences;
    return Scaffold(
      appBar: AppBar(title: const Text('应用更新')),
      body: preferences == null
          ? Center(
              child: _loadFailed
                  ? const Text('无法读取更新设置。')
                  : const CircularProgressIndicator(),
            )
          : ListView(
              children: [
                FutureBuilder<String?>(
                  future: widget.version,
                  builder: (_, snapshot) => ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('当前版本'),
                    subtitle: Text(snapshot.data ?? '—'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: const Text('检查更新'),
                  subtitle: _message == null ? null : Text(_message!),
                  onTap: _busy ? null : _check,
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('自动检查更新'),
                  subtitle: const Text('启动或返回应用时检查，最多每小时一次'),
                  value: preferences.automaticCheck,
                  onChanged: _busy
                      ? null
                      : (value) => _save(automaticCheck: value),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: '更新来源'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<UpdateSource>(
                        isExpanded: true,
                        isDense: true,
                        value: preferences.mode,
                        items: const [
                          DropdownMenuItem(
                            value: UpdateSource.automatic,
                            child: Text('自动选择'),
                          ),
                          DropdownMenuItem(
                            value: UpdateSource.github,
                            child: Text('仅 GitHub'),
                          ),
                          DropdownMenuItem(
                            value: UpdateSource.custom,
                            child: Text('指定镜像'),
                          ),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) async {
                                if (value == UpdateSource.custom &&
                                    preferences.host == null) {
                                  await _chooseMirror();
                                } else if (value != null) {
                                  await _save(source: value);
                                }
                              },
                      ),
                    ),
                  ),
                ),
                if (preferences.mode == UpdateSource.custom)
                  ListTile(
                    title: const Text('镜像地址'),
                    subtitle: Text(preferences.host ?? '选择或输入 HTTPS 镜像'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: _busy ? null : _chooseMirror,
                  ),
              ],
            ),
    );
  }
}

class _MirrorDialog extends StatefulWidget {
  const _MirrorDialog({required this.initialHost, required this.hosts});
  final String? initialHost;
  final List<String> hosts;

  @override
  State<_MirrorDialog> createState() => _MirrorDialogState();
}

class _MirrorDialogState extends State<_MirrorDialog> {
  late final _input = TextEditingController(text: widget.initialHost);
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('指定镜像'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: '从候选名单选择'),
              items: [
                for (final host in widget.hosts)
                  DropdownMenuItem(
                    value: host,
                    child: Text(host, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (host) {
                if (host != null) _input.text = host;
                setState(() => _error = null);
              },
            ),
            TextField(
              controller: _input,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'HTTPS 镜像域名',
                errorText: _error,
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final host = mirrorHost(_input.text);
          if (host == null) {
            setState(() => _error = '请输入域名，例如 gh-proxy.com');
          } else {
            Navigator.pop(context, host);
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}

Future<void> showUpdate(
  BuildContext context,
  AppUpdates updates,
  String version,
  AppRelease release,
  UpdatePreferences preferences,
) => showDialog<void>(
  context: context,
  builder: (_) => _UpdateDialog(
    updates: updates,
    version: version,
    release: release,
    preferences: preferences,
  ),
);

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.updates,
    required this.version,
    required this.release,
    required this.preferences,
  });
  final AppUpdates updates;
  final String version;
  final AppRelease release;
  final UpdatePreferences preferences;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  UpdateAsset? _asset;
  CancelToken? _cancel;
  File? _file;
  int _received = 0;
  String? _error;

  List<UpdateAsset> get _packages => widget.release.assets
      .where((asset) => asset.platform == Platform.operatingSystem)
      .toList();

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _download(UpdateAsset asset) async {
    final cancel = CancelToken();
    setState(() {
      _cancel = cancel;
      _asset = asset;
      _error = null;
      _received = 0;
    });
    Directory? folder;
    try {
      final cache = await getTemporaryDirectory();
      final updates = await Directory(
        '${cache.path}${Platform.pathSeparator}pixdraft-updates',
      ).create(recursive: true);
      folder = await updates.createTemp('release-');
      final file = await widget.updates.download(
        widget.release,
        asset,
        folder,
        widget.preferences,
        cancel: cancel,
        onProgress: (received) {
          if (mounted) setState(() => _received = received);
        },
      );
      if (mounted && !cancel.isCancelled) {
        setState(() => _file = file);
        folder = null;
      }
    } catch (_) {
      if (mounted && !cancel.isCancelled) {
        setState(() => _error = '安装包下载或校验失败，请重试。');
      }
    } finally {
      try {
        await folder?.delete(recursive: true);
      } on FileSystemException {
        // 缓存目录由系统清理。
      }
      if (mounted) setState(() => _cancel = null);
    }
  }

  Future<void> _open(Uri uri, {File? file}) async {
    try {
      final opened = file != null && Platform.isAndroid
          ? await const MethodChannel('image_gen/update')
                    .invokeMethod<bool>('openApk', {'path': file.path}) ==
                true
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (opened) return;
    } on Exception {
      // 系统无法打开时允许用户重试。
    }
    if (mounted) {
      setState(
        () =>
            _error = file == null ? '无法打开 GitHub 发布页。' : '无法打开安装包，请检查系统设置后重试。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final packages = _packages;
    final selected = _asset ?? packages.firstOrNull;
    final file = _file;
    return AlertDialog(
      title: Text('Pixdraft ${widget.release.tag} 可用'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前版本 ${widget.version}'),
            if (widget.release.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              SelectableText(widget.release.notes),
            ],
            if (packages.isNotEmpty && file == null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<UpdateAsset>(
                isExpanded: true,
                initialValue: selected,
                decoration: const InputDecoration(labelText: '安装包'),
                items: [
                  for (final asset in packages)
                    DropdownMenuItem(
                      value: asset,
                      child: Text(asset.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _cancel != null
                    ? null
                    : (asset) => setState(() => _asset = asset),
              ),
            ],
            if (_cancel != null && selected != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _received / selected.size),
              const SizedBox(height: 8),
              Text(_received == selected.size ? '正在校验安装包…' : '正在下载安装包…'),
            ],
            if (file != null) const Text('安装包已下载并通过校验。'),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        if (_cancel case final cancel?)
          TextButton(onPressed: cancel.cancel, child: const Text('取消下载'))
        else ...[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () => _open(widget.release.page),
            child: const Text('GitHub 发布页'),
          ),
          if (file != null)
            FilledButton(
              onPressed: () => _open(file.uri, file: file),
              child: const Text('打开安装包'),
            )
          else if (selected != null)
            FilledButton(
              onPressed: () => _download(selected),
              child: const Text('下载'),
            ),
        ],
      ],
    );
  }
}
