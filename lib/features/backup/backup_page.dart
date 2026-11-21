import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/studio_store.dart';
import 'backup_encryption.dart';
import 'backup_file_io.dart';
import 'backup_service.dart';
import 'backup_options.dart';
import '../../platform/local_file_picker.dart';

class BackupPage extends StatefulWidget {
  const BackupPage({super.key, required this.store, this.service});

  final BackupService? service;
  final StudioStore store;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  late final BackupService _service =
      widget.service ?? BackupService(widget.store);
  final _exportButtonKey = GlobalKey();
  bool _busy = false;
  String? _status;
  (String, int?)? _exportProgress;

  @override
  void initState() {
    super.initState();
    _recover();
  }

  Future<void> _recover() async {
    try {
      await _service.recoverInterruptedImports();
    } catch (_) {
      // Recovery is best effort; a later import retries it.
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final options = await showDialog<BackupOptions>(
        context: context,
        builder: (_) => const _BackupOptionsDialog(),
      );
      if (options == null || !mounted) return;
      setState(() {
        _status = null;
        _exportProgress = ('正在准备备份', null);
      });
      if (kIsWeb) {
        final backup = await _service.exportWebBackup(options: options);
        if (!mounted) return;
        await FilePicker.saveFile(fileName: backup.fileName, bytes: backup.bytes);
        if (mounted) setState(() => _status = '已发起下载：${backup.fileName}');
        return;
      }
      final files = await _service.writeExportFiles(
        options: options,
        onProgress: (stage, completed, total) {
          final progress = (
            stage,
            total == 0 ? null : completed * 100 ~/ total,
          );
          if (mounted && progress != _exportProgress) {
            setState(() => _exportProgress = progress);
          }
        },
      );
      try {
        if (!mounted) return;
        final box = _exportButtonKey.currentContext?.findRenderObject();
        final origin = box is RenderBox && box.attached && box.hasSize
            ? box.localToGlobal(Offset.zero) & box.size
            : null;
        setState(
          () => _exportProgress = (
            switch (defaultTargetPlatform) {
              TargetPlatform.android => '正在保存到下载目录',
              TargetPlatform.iOS => '请在系统面板选择「存储到文件」',
              _ => '正在保存备份',
            },
            null,
          ),
        );
        final status = await saveBackupFiles(files, shareOrigin: origin);
        if (mounted) setState(() => _status = status ?? '已取消导出');
      } finally {
        for (final file in files) {
          try {
            await file.delete();
          } on FileSystemException {
            // 缓存清理失败不改变公开备份的保存结果。
          }
        }
      }
    } on BackupException catch (error) {
      _showError(error.message);
    } on PlatformException catch (error) {
      _showError(error.message ?? '无法保存备份文件');
    } catch (error) {
      _showError('导出失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _exportProgress = null;
        });
      }
    }
  }

  Future<void> _import() async {
    BackupImportPlan? plan;
    setState(() => _busy = true);
    try {
      Uint8List? webBytes;
      late List<File> files;
      final bool encrypted;
      if (kIsWeb) {
        final picked = await FilePicker.pickFile(
          webOptions: localFilePickerOptions(),
        );
        if (picked == null || !mounted) return;
        final length = picked.lengthSync();
        if (length == null || length > webBackupMaxBytes) {
          throw const BackupException('网页端仅支持最大 64 MiB 的单个备份文件');
        }
        webBytes = await picked.readAsBytes();
        encrypted = isEncryptedBackup(webBytes);
      } else {
        final picked = await FilePicker.pickFiles(
          // Android 不认识 .igbackup 的 MIME，格式由备份内容校验。
          type: FileType.any,
          dialogTitle: '选择 Pixdraft 备份',
        );
        if (picked.isEmpty || !mounted) return;
        if (picked.any((file) => file.path == null)) {
          throw const BackupException('无法读取所选备份文件');
        }
        files = picked.map((file) => File(file.path!)).toList();
        encrypted = await _service.isEncryptedBackupFiles(files);
      }
      String? password;
      if (encrypted) {
        if (!mounted) return;
        password = await showDialog<String>(
          context: context,
          builder: (_) => const _ImportPasswordDialog(),
        );
        if (password == null || !mounted) return;
      }
      plan = webBytes == null
          ? await _service.prepareImportFiles(files, password: password)
          : await _service.prepareWebImport(webBytes, password: password);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认导入'),
          content: SingleChildScrollView(child: Text(plan!.preview.summary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        await plan.dispose();
        return;
      }
      final result = await plan.commit();
      if (mounted) {
        setState(
          () => _status =
              '导入完成：新增 ${result.preview.tasks} 条任务、${result.preview.assets} 张图片。\n${result.preview.warnings.join('\n')}',
        );
      }
    } on BackupException catch (error) {
      await plan?.dispose();
      _showError(error.message);
    } catch (error) {
      await plan?.dispose();
      _showError('导入失败：$error');
    } finally {
      await plan?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final exportProgress = _exportProgress;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本地备份', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text('选择要包含的作品与历史、供应商与模型、提示词库、设置与草稿、错误记录；回收站单独选择。'),
                  const SizedBox(height: 8),
                  Text(kIsWeb ? '网页端仅支持单文件。备份文件与解压后内容均不得超过 64 MiB。' : switch (defaultTargetPlatform) {
                    TargetPlatform.android => '备份保存到「下载/image-gen-backup」。',
                    TargetPlatform.iOS => '在系统分享面板中选择「存储到文件」以保存备份。',
                    _ => '导出时可选择备份保存目录。',
                  }),
                  Text(kIsWeb ? '备份通过浏览器下载。默认不包含凭据，可用密码加密。' : '默认不包含凭据，也不加密。可用密码加密或按 512 MiB 分包。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: _exportButtonKey,
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.download_outlined),
            label: const Text('导出备份'),
          ),
          if (exportProgress case (final stage, final percent)) ...[
            const SizedBox(height: 16),
            Text(percent == null ? stage : '$stage：$percent%'),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percent == null ? null : percent / 100,
              semanticsLabel: stage,
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _import,
            icon: const Icon(Icons.restore),
            label: const Text('从备份导入'),
          ),
          if (_busy && exportProgress == null) ...const [
            SizedBox(height: 16),
            LinearProgressIndicator(),
          ],
          if (_status != null) ...[const SizedBox(height: 16), Text(_status!)],
        ],
      ),
    );
  }
}

class _BackupOptionsDialog extends StatefulWidget {
  const _BackupOptionsDialog();

  @override
  State<_BackupOptionsDialog> createState() => _BackupOptionsDialogState();
}

class _BackupOptionsDialogState extends State<_BackupOptionsDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _encrypted = false;
  bool _includeCredentials = false;
  bool _works = true,
      _providers = true,
      _prompts = true,
      _settings = true,
      _errors = true;
  bool _trash = false, _split = false;
  bool _emptySelection = false;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_encrypted && !_form.currentState!.validate()) return;
    if (!_works &&
        !_providers &&
        !_prompts &&
        !_settings &&
        !_errors &&
        !_trash) {
      setState(() => _emptySelection = true);
      return;
    }
    _emptySelection = false;
    Navigator.pop(
      context,
      BackupOptions(
        works: _works,
        providers: _providers,
        includeCredentials: _providers && _includeCredentials,
        prompts: _prompts,
        settings: _settings,
        errors: _errors,
        trash: _trash,
        split: _split,
        password: _encrypted ? _password.text : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出备份'),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in [
              ('作品与历史', _works, (bool value) => _works = value),
              (
                '供应商与模型',
                _providers,
                (bool value) {
                  _providers = value;
                  if (!value) _includeCredentials = false;
                },
              ),
              ('提示词库', _prompts, (bool value) => _prompts = value),
              ('设置与草稿', _settings, (bool value) => _settings = value),
              ('错误记录', _errors, (bool value) => _errors = value),
              ('回收站', _trash, (bool value) => _trash = value),
            ])
              CheckboxListTile(
                value: item.$2,
                onChanged: (value) => setState(() => item.$3(value!)),
                contentPadding: EdgeInsets.zero,
                title: Text(item.$1),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            if (_emptySelection)
              const Text('请至少选择一类备份内容。', style: TextStyle(color: Colors.red)),
            if (!kIsWeb) CheckboxListTile(
              value: _split,
              onChanged: (value) => setState(() => _split = value!),
              contentPadding: EdgeInsets.zero,
              title: const Text('分包（每包 512 MiB）'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              value: _includeCredentials,
              onChanged: _providers
                  ? (value) => setState(() => _includeCredentials = value!)
                  : null,
              contentPadding: EdgeInsets.zero,
              title: const Text('包含 API 密钥等凭据'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_includeCredentials && !_encrypted)
              const Text('未加密的凭据可被任何取得备份文件的人读取。建议用密码加密。'),
            CheckboxListTile(
              value: _encrypted,
              onChanged: (value) => setState(() => _encrypted = value!),
              contentPadding: EdgeInsets.zero,
              title: const Text('用密码加密'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 12),
            if (_encrypted) ...[
              TextFormField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 1024,
                decoration: const InputDecoration(
                  labelText: '备份密码',
                  counterText: '',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) return '请输入备份密码';
                  if (value.length < 8) return '请使用至少 8 个字符';
                  return null;
                },
                onFieldSubmitted: null,
              ),
              ...[
                const SizedBox(height: 20),
                TextFormField(
                  controller: _confirmation,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '再次输入密码'),
                  validator: (value) =>
                      value == _password.text ? null : '两次密码不一致',
                  onFieldSubmitted: (_) => _confirm(),
                ),
                const SizedBox(height: 16),
                const Text('密码不会保存，遗失后无法恢复备份。'),
              ],
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _confirm, child: const Text('导出')),
    ],
  );
}

class _ImportPasswordDialog extends StatefulWidget {
  const _ImportPasswordDialog();

  @override
  State<_ImportPasswordDialog> createState() => _ImportPasswordDialogState();
}

class _ImportPasswordDialogState extends State<_ImportPasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('输入备份密码'),
    content: TextField(
      controller: _password,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: '备份密码'),
      onSubmitted: (_) => Navigator.pop(context, _password.text),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _password.text),
        child: const Text('解锁'),
      ),
    ],
  );
}
