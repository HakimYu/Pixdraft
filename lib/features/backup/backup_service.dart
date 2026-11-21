import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/image_validation.dart';
import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/plugin_manager.dart';
import 'backup_encryption.dart';
import 'backup_options.dart';
import 'backup_parts.dart';

const _format = 'image-gen.backup';
const _formatVersion = 2;
const _stagingFolder = 'backup-staging';
const _maxEntries = 20000;
const _maxFileBytes = 64 * 1024 * 1024;
const _maxManifestBytes = 16 * 1024 * 1024;
const _maxCompressionRatio = 200;
const _maxMetadataChars = 100000;

const webBackupMaxBytes = 64 * 1024 * 1024;
const _webBackupLimitMessage = '网页端备份文件和解压后内容均不得超过 64 MiB';
const _mimeByExtension = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
};
const _extensionByMime = {
  'image/png': 'png',
  'image/jpeg': 'jpeg',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'image/svg+xml': 'svg',
};
const _secretKeys = {
  'apikey',
  'api_key',
  'api-key',
  'token',
  'secret',
  'password',
  'authorization',
  'credential',
  'credentials',
  'accesstoken',
  'access_token',
  'refreshtoken',
  'refresh_token',
  'authtoken',
  'auth_token',
  'idtoken',
  'id_token',
  'clientsecret',
  'client_secret',
  'apisecret',
  'api_secret',
};
const _assetPathPattern = r'^assets/[a-f0-9]{64}\.(png|jpeg|webp|gif|svg)$';
const _taskStatuses = {
  'queued',
  'running',
  'done',
  'error',
  'partialError',
  'aborted',
  'interrupted',
};
const _relationRoles = {'input', 'output', 'mask', 'markup', 'derived'};
const _upstreamParams = {
  'size',
  'quality',
  'output_format',
  'output_compression',
  'moderation',
  'n',
  'background',
  'input_fidelity',
  'complexity',
  'frame_count',
  'frame_duration_ms',
};

typedef BackupExportProgress = void Function(String stage, int completed, int total);

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupExport {
  const BackupExport({
    required this.bytes,
    required this.fileName,
    required this.tasks,
    required this.assets,
    required this.attempts,
    required this.providers,
    required this.categories,
    required this.prompts,
    required this.settings,
  });

  final Uint8List bytes;
  final String fileName;
  final int tasks;
  final int assets;
  final int attempts;
  final int providers;
  final int categories;
  final int prompts;
  final int settings;
}

class BackupImportPreview {
  const BackupImportPreview({
    required this.format,
    required this.tasks,
    required this.duplicateTasks,
    required this.remappedTasks,
    required this.assets,
    required this.duplicateAssets,
    required this.providersAdded,
    required this.providersMerged,
    required this.categoriesAdded,
    required this.categoriesMerged,
    required this.promptsAdded,
    required this.promptsMerged,
    required this.settingsAdded,
    required this.settingsSkipped,
    required this.warnings,
  });

  final String format;
  final int tasks;
  final int duplicateTasks;
  final int remappedTasks;
  final int assets;
  final int duplicateAssets;
  final int providersAdded;
  final int providersMerged;
  final int categoriesAdded;
  final int categoriesMerged;
  final int promptsAdded;
  final int promptsMerged;
  final int settingsAdded;
  final int settingsSkipped;
  final List<String> warnings;

  String get summary {
    final buffer = StringBuffer()
      ..writeln('格式：$format')
      ..writeln('')
      ..writeln(
        '将新增 $tasks 条任务，跳过 $duplicateTasks 条重复任务，重映射 $remappedTasks 条冲突任务。',
      )
      ..writeln('将新增 $assets 张图片，复用 $duplicateAssets 张已有图片。')
      ..writeln(
        '供应商：新增 $providersAdded，复用 $providersMerged；分类：新增 $categoriesAdded，复用 $categoriesMerged；提示词：新增 $promptsAdded，复用 $promptsMerged。',
      )
      ..writeln('设置草稿：新增 $settingsAdded，保留本地 $settingsSkipped。');
    if (warnings.isNotEmpty) {
      buffer
        ..writeln('')
        ..writeln('注意：');
      for (final warning in warnings) {
        buffer.writeln('• $warning');
      }
    }
    return buffer.toString().trim();
  }
}

class BackupImportResult {
  const BackupImportResult(this.preview);

  final BackupImportPreview preview;
}

class BackupImportPlan {
  BackupImportPlan._(this._service, this.preview, this._prepared);

  final BackupService _service;
  final BackupImportPreview preview;
  final _PreparedImport _prepared;
  bool _finished = false;

  Future<BackupImportResult> commit() async {
    if (_finished) throw const BackupException('导入会话已结束');
    _finished = true;
    return _service._commit(_prepared);
  }

  Future<void> dispose() async {
    if (_finished) return;
    _finished = true;
    await _service._discard(_prepared);
  }
}

class BackupService {
  BackupService(this.store, [this._tempDirectory]);

  final StudioStore store;
  final Directory? _tempDirectory;

  static final RegExp _safeSegment = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _assetPathRegExp = RegExp(_assetPathPattern);
  static final Set<String> _activeSessions = <String>{};
  static Future<void> _operationTail = Future<void>.value();

  Future<T> _operation<T>(Future<T> Function() body) {
    final run = _operationTail.then((_) => body());
    _operationTail = run.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return run;
  }


  Future<BackupExport> exportWebBackup({required BackupOptions options, BackupExportProgress? onProgress}) => _operation(() async {
    if (options.split) throw const BackupException('网页端仅支持单文件备份');
    return await _writeSelectedExport(options, onProgress, inMemory: true) as BackupExport;
  });
  Future<File> writeExportFile({
    String? password,
    BackupOptions? options,
    BackupExportProgress? onProgress,
  }) async => await _writeSelectedExport(
    options ?? BackupOptions(password: password), onProgress, inMemory: false,
  ) as File;

  Future<Object> _writeSelectedExport(BackupOptions selected, BackupExportProgress? onProgress, {required bool inMemory}) async {
    if (selected.isEmpty) throw const BackupException('请至少选择一类备份内容');
    if (selected.password != null &&
        (selected.password!.length < 8 || selected.password!.length > 1024)) {
      throw const BackupException('备份密码须为 8～1024 个字符');
    }
    final snapshot = await store.db.transaction((tx) async {
      await _assertIdle(tx);
      return <String, List<Map<String, Object?>>>{
        for (final table in [
          'providers',
          'assets',
          'tasks',
          'task_assets',
          'attempts',
          'categories',
          'prompts',
          'settings',
          'errors',
          'pipeline_state',
        ])
          table: await tx.query(table),
      };
    });
    final tasks = (snapshot['tasks']!.toList()
      ..removeWhere((row) {
        final deleted = row['deleted_at'] != null;
        return deleted ? !selected.trash : !selected.works;
      }));
    final taskIds = tasks.map((row) => row['id'] as String).toSet();
    final taskAssets = (snapshot['task_assets']!.toList()
      ..removeWhere((row) => !taskIds.contains(row['task_id'])));
    final attempts = (snapshot['attempts']!.toList()
      ..removeWhere((row) => !taskIds.contains(row['task_id'])));
    final pipeline = (snapshot['pipeline_state']!.toList()
      ..removeWhere((row) => !taskIds.contains(row['task_id'])));
    final selectedAssetIds = <String>{
      for (final relation in taskAssets) relation['asset_id'] as String,
    };
    for (final row in tasks) {
      try {
        for (final inputRow in [row['input'], row['original_input']]) {
          if (inputRow == null || inputRow == '') continue;
          final input = inputRow is String
              ? decodeObject(inputRow)
              : Map<String, dynamic>.from(inputRow as Map);
          void addAsset(dynamic raw) {
            if (raw is Map && raw['id'] is String) {
              selectedAssetIds.add(raw['id'] as String);
            }
          }

          for (final raw in (input['references'] as List? ?? const [])) {
            addAsset(raw);
          }
          addAsset(input['mask']);
          addAsset(input['markup']);
          if (input['parentAssetId'] is String) {
            selectedAssetIds.add(input['parentAssetId'] as String);
          }
          for (final steps in [
            input['preprocessors'],
            input['postprocessors'],
          ]) {
            if (steps is! List) continue;
            for (final step in steps) {
              if (step is Map && step['params'] is Map) {
                _collectAssetReferences(step['params'], selectedAssetIds);
              }
            }
          }
        }
      } catch (_) {
        throw BackupException('任务 ${row['id']} 的输入无效，无法导出');
      }
    }
    for (final row in pipeline) {
      final sourceId = row['source_asset_id'];
      if (sourceId is String) selectedAssetIds.add(sourceId);
    }
    final assets = (snapshot['assets']!.toList()
      ..removeWhere((row) => !selectedAssetIds.contains(row['id'])));
    final providers = selected.providers
        ? snapshot['providers']!
        : <Map<String, Object?>>[];
    final categories = selected.works
        ? snapshot['categories']!
              .where(
                (row) => tasks.any((task) => task['category_id'] == row['id']),
              )
              .toList()
        : <Map<String, Object?>>[];
    final prompts = selected.prompts
        ? snapshot['prompts']!
        : <Map<String, Object?>>[];
    final settingsRows = selected.settings
        ? snapshot['settings']!
        : <Map<String, Object?>>[];
    final errors = selected.errors
        ? snapshot['errors']!
              .where(
                (row) =>
                    row['task_id'] == null || taskIds.contains(row['task_id']),
              )
              .toList()
        : <Map<String, Object?>>[];
    final storedCredentials = selected.providers && selected.includeCredentials
        ? await store.credentials.readAll()
        : <String, String>{};
    final credentials = <String, String>{
      for (final entry in storedCredentials.entries)
        if (!entry.key.startsWith('provider:')) entry.key: entry.value,
    };
    for (final row in providers) {
      final key = "provider:${row['id']}";
      final value = storedCredentials[key];
      if (value == null) continue;
      final config = ProviderConfig.fromJson(decodeObject(row['config'] as String));
      final secret = StudioStore.providerKeyForOrigin(value, config.baseUrl);
      if (secret != null) credentials[key] = secret;
    }
    final temp = inMemory ? null : (_tempDirectory ?? await getTemporaryDirectory());
    await temp?.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final work = temp == null ? null : await Directory('${temp.path}/backup-export-$stamp-${newId()}').create();
    try {
      final exportedAssets = <Map<String, dynamic>>[];
      final entries = <(File, String)>[];
      final archive = inMemory ? Archive() : null;
      var assetBytes = 0;
      if (assets.isNotEmpty) onProgress?.call('校验图片', 0, assets.length);
      for (final row in assets) {
        final data = decodeObject(row['data'] as String);
        final path = data['path'] as String;
        final hash = data['hash'] as String;
        if (!_assetPathRegExp.hasMatch(path) || !path.contains(hash)) {
          throw BackupException('本地图片记录路径无效：$path');
        }
        if (archive != null) {
          final asset = ImageAsset.fromJson(data);
          if (asset.bytes > webBackupMaxBytes - assetBytes) {
            throw const BackupException(_webBackupLimitMessage);
          }
          final Uint8List bytes;
          try {
            bytes = await store.readAsset(asset);
          } on PathNotFoundException {
            throw BackupException('本地图片文件缺失：$path');
          }
          if (bytes.length != asset.bytes) throw BackupException('本地图片大小与记录不一致：$path');
          if (await _sha256(bytes) != hash) throw BackupException('本地图片文件与记录哈希不一致：$path');
          await _validateImage(bytes, asset.mime, path);
          if (archive.findFile(path) == null) {
            assetBytes += bytes.length;
            archive.add(ArchiveFile.bytes(path, bytes));
          }
        } else {
          final file = File('${store.root.path}/$path');
          if (!await file.exists()) throw BackupException('本地图片文件缺失：$path');
          final length = await file.length();
          if (length > _maxFileBytes)
            throw const BackupException('本地单张图片超过 64 MB，无法导出');
          final actualHash = await _sha256File(file);
          if (actualHash != hash) throw BackupException('本地图片文件与记录哈希不一致：$path');
          final bytes = await file.readAsBytes();
          await _validateImage(bytes, data['mime'] as String, path);
          entries.add((file, path));
        }
        exportedAssets.add(data);
        onProgress?.call('校验图片', exportedAssets.length, assets.length);
      }
      final settings = <String, dynamic>{};
      for (final row in settingsRows) {
        final key = row['key'] as String;
        if (key != pluginIndexKey && key != StudioStore.draftRevisionKey &&
            (selected.includeCredentials || !_isSecretKey(key)))
          settings[key] = selected.includeCredentials ? jsonDecode(row['value'] as String) : _sanitize(jsonDecode(row['value'] as String));
      }
      final manifest = <String, dynamic>{
        'format': _format,
        'version': _formatVersion,
        'app': 'image-gen',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'containsApiKeys': credentials.isNotEmpty,
        'credentials': credentials,
        'errors': errors,
        'providers': providers
            .map((row) {
              final config = decodeObject(row['config'] as String);
              return selected.includeCredentials ? config : _sanitize(config);
            })
            .toList(),
        'categories': categories,
        'prompts': prompts,
        'settings': settings,
        'assets': exportedAssets,
        'tasks': selected.includeCredentials ? tasks : _redactExportRows(tasks, ['input', 'original_input']),
        'taskAssets': taskAssets,
        'attempts': selected.includeCredentials ? attempts : _redactExportRows(attempts, ['metadata']),
        'pluginDependencies': selected.works
            ? _pluginDependencies(tasks, kIsWeb ? PluginManager.builtinPlugins : await PluginManager(store).list())
            : const [],
        'pipelineState': pipeline,
      };
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      if (manifestBytes.length > _maxManifestBytes) {
        throw const BackupException('备份记录超过 16 MB，无法导出');
      }
      if (entries.length + 1 > _maxEntries) {
        throw const BackupException('备份文件数超过 20000');
      }
      if (archive != null) {
        if (assetBytes + manifestBytes.length > webBackupMaxBytes || archive.length + 1 > _maxEntries) {
          throw const BackupException(_webBackupLimitMessage);
        }
        archive.add(ArchiveFile.bytes('manifest.json', manifestBytes));
        onProgress?.call('打包备份', 0, 0);
        var bytes = ZipEncoder().encodeBytes(archive, level: 0);
        final password = selected.password;
        if (bytes.length + (password == null ? 0 : 52) > webBackupMaxBytes) {
          throw const BackupException(_webBackupLimitMessage);
        }
        if (password != null) {
          onProgress?.call('加密备份', 0, 0);
          bytes = await encryptBackup(bytes, password);
        }
        return BackupExport(
          bytes: bytes,
          fileName: 'image-gen-backup-$stamp.${password == null ? 'zip' : 'igbackup'}',
          tasks: tasks.length, assets: exportedAssets.length, attempts: attempts.length,
          providers: providers.length, categories: categories.length, prompts: prompts.length, settings: settings.length,
        );
      }
      final zipFile = File('${work!.path}/backup.zip');
      final manifestFile = File('${work.path}/manifest.json');
      await manifestFile.writeAsBytes(manifestBytes, flush: true);
      final entryCount = entries.length + 1;
      onProgress?.call('打包备份', 0, entryCount);
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path, level: ZipFileEncoder.store);
      try {
        await encoder.addFile(
          manifestFile,
          'manifest.json',
          ZipFileEncoder.store,
        );
        var completed = 1;
        final added = <String>{'manifest.json'};
        for (final (file, path) in entries) {
          onProgress?.call('打包备份', completed, entryCount);
          if (added.add(path)) {
            await encoder.addFile(file, path, ZipFileEncoder.store);
          }
          completed++;
        }
      } finally {
        await encoder.close();
      }
      onProgress?.call('打包备份', entryCount, entryCount);
      File result = zipFile;
      var extension = 'zip';
      if (selected.password != null) {
        final encryptedFile = File('${work.path}/backup.igbackup');
        await encryptBackupFile(
          zipFile,
          encryptedFile,
          selected.password!,
          onProgress: (completed, total) =>
              onProgress?.call('加密备份', completed, total),
        );
        result = encryptedFile;
        extension = 'igbackup';
      }
      final output = File('${temp!.path}/image-gen-backup-$stamp-${newId()}.$extension');
      await result.rename(output.path);
      return output;
    } finally {
      if (work != null && await work.exists()) await _deleteTree(work);
    }
  }

  Future<List<File>> writeExportFiles({
    required BackupOptions options,
    int partSize = backupPartSize,
    BackupExportProgress? onProgress,
  }) async {
    final file = await writeExportFile(options: options, onProgress: onProgress);
    if (!options.split) return [file];
    try {
      final parts = await splitBackupFile(
        file,
        _tempDirectory ?? await getTemporaryDirectory(),
        partSize: partSize,
        onProgress: (completed, total) =>
            onProgress?.call('拆分备份', completed, total),
      );
      await file.delete();
      return parts;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<BackupImportPlan> prepareImportFile(
    File file, {
    String? password,
  }) async {
    if (!await isEncryptedBackupFile(file)) {
      return prepareImportFileUnencrypted(file);
    }
    if (password == null) throw const BackupException('此备份已加密，请输入密码');
    final directory = _tempDirectory ?? store.root;
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/backup-import-${newId()}.zip');
    try {
      try {
        await decryptBackupFile(file, temporary, password);
      } on FormatException catch (error) {
        throw BackupException(error.message);
      }
      return await prepareImportFileUnencrypted(temporary);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<BackupImportPlan> prepareImportFileUnencrypted(File file) async {
    return _operation(() async {
      await _recoverUnlocked();
      await _assertIdle(store.db);
      final base = Directory('${store.root.path}/$_stagingFolder');
      await base.create(recursive: true);
      final extracted = await base.createTemp('extract-');
      try {
        final files = await _unzipFile(file, extracted);
        return await _prepareImportFiles(files);
      } finally {
        await _deleteTree(extracted);
      }
    });
  }

  Future<BackupImportPlan> prepareImportFiles(
    List<File> files, {
    String? password,
    int partSize = backupPartSize,
  }) async {
    if (files.isEmpty) throw const BackupException('未选择备份文件');
    if (files.length == 1 && !await _isPart(files.single, partSize)) {
      return prepareImportFile(files.single, password: password);
    }
    final directory = _tempDirectory ?? await getTemporaryDirectory();
    await directory.create(recursive: true);
    File? joined;
    try {
      try {
        joined = await joinBackupParts(files, directory, partSize: partSize);
      } on FormatException catch (error) {
        throw BackupException(error.message);
      }
      return await prepareImportFile(joined, password: password);
    } finally {
      if (joined != null && await joined.exists()) await joined.delete();
    }
  }

  Future<bool> _isPart(File file, int partSize) async {
    try {
      return await readBackupPartInfo(file, partSize: partSize) != null;
    } on FormatException catch (error) {
      throw BackupException(error.message);
    }
  }
  Future<bool> isEncryptedBackupFiles(
    List<File> files, {
    int partSize = backupPartSize,
  }) async {
    if (files.isEmpty) throw const BackupException('未选择备份文件');
    if (files.length == 1 && !await _isPart(files.single, partSize)) {
      return isEncryptedBackupFile(files.single);
    }
    final directory = _tempDirectory ?? await getTemporaryDirectory();
    await directory.create(recursive: true);
    File? joined;
    try {
      joined = await joinBackupParts(files, directory, partSize: partSize);
      return await isEncryptedBackupFile(joined);
    } finally {
      if (joined != null && await joined.exists()) await joined.delete();
    }
  }

  Future<BackupImportPlan> prepareWebImport(Uint8List bytes, {String? password}) => _operation(() async {
    if (bytes.length > webBackupMaxBytes) throw const BackupException(_webBackupLimitMessage);
    if (isEncryptedBackup(bytes)) {
      if (password == null) throw const BackupException('此备份已加密，请输入密码');
      try {
        bytes = await decryptBackup(bytes, password);
      } on FormatException catch (error) {
        throw BackupException(error.message);
      }
    }
    await _assertIdle(store.db);
    final files = await _unzip(InputMemoryStream(bytes), bytes.length, null);
    return _prepareImportFiles(files, inMemory: true);
  });
  Future<BackupImportPlan> prepareImport(
    List<int> zipBytes, {
    String? password,
  }) async {
    if (zipBytes.isEmpty) throw const BackupException('备份文件为空');
    final directory = _tempDirectory ?? store.root;
    await directory.create(recursive: true);
    final file = File('${directory.path}/backup-input-${newId()}.zip');
    try {
      await file.writeAsBytes(zipBytes);
      return await prepareImportFile(file, password: password);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<BackupImportPlan> _prepareImportFiles(
    Map<String, _ImportEntry> files, {
    bool inMemory = false,
  }
  ) async {
    final manifestFile = files['manifest.json'];
    if (manifestFile == null)
      throw const BackupException('ZIP 中缺少 manifest.json');
    final manifestBytes = await manifestFile.readAsBytes();

    Map<String, dynamic> manifest;
    try {
      final decoded = jsonDecode(utf8.decode(manifestBytes));
      if (decoded is! Map) throw const FormatException();
      manifest = Map<String, dynamic>.from(decoded);
    } catch (_) {
      throw const BackupException('manifest.json 不是有效的 JSON 对象');
    }

    final ownFormat = manifest['format'] == _format;
    if (manifest['format'] != null && !ownFormat) {
      throw BackupException('不支持的备份格式：${manifest['format']}');
    }

    final existing = await _loadExisting();
    final prepared = ownFormat
        ? await _prepareOwn(manifest, files, existing)
        : await _prepareUpstream(manifest, files, existing);
    _activeSessions.add(prepared.sessionId);
    try {
      if (!inMemory && prepared.stagedAssets.isNotEmpty) await _stage(prepared);
      return BackupImportPlan._(this, prepared.preview, prepared);
    } catch (error) {
      _activeSessions.remove(prepared.sessionId);
      await _cleanupBestEffort(prepared);
      rethrow;
    }
  }

  Future<Map<String, _ImportEntry>> _unzipFile(File source, Directory target) async {
    final input = InputFileStream(source.path);
    try {
      return await _unzip(input, await source.length(), target);
    } finally {
      input.close();
    }
  }

  Future<Map<String, _ImportEntry>> _unzip(InputStream input, int length, Directory? target) async {
    try {
      if (length == 0) throw const BackupException('备份文件为空');
      final directory = ZipDirectory();
      final names = <String, int>{};
      var declared = 0;
      for (final header in directory.headers(input, files: false)) {
        final name = header.filename;
        _validateArchivePath(name);
        if (names.containsKey(name)) throw BackupException('ZIP 包含重复条目：$name');
        names[name] = header.uncompressedSize;
        if (names.length > _maxEntries) {
          throw const BackupException('ZIP 条目数超过 20000');
        }
        if ((header.externalFileAttributes >> 16) & 0xf000 == 0xa000) {
          throw const BackupException('ZIP 不允许符号链接');
        }
        final limit = name == 'manifest.json' ? _maxManifestBytes : _maxFileBytes;
        if (header.uncompressedSize < 0 || header.uncompressedSize > limit) {
          throw BackupException('ZIP 条目超过 ${limit ~/ (1024 * 1024)} MB：$name');
        }
        declared += header.uncompressedSize;
        if (target == null && declared > webBackupMaxBytes) {
          throw const BackupException(_webBackupLimitMessage);
        }
        if (declared > length * _maxCompressionRatio) {
          throw const BackupException('ZIP 压缩比异常，可能是压缩炸弹');
        }
      }
      final archive = ZipDecoder().decodeStream(input, verify: true);
      final files = <String, _ImportEntry>{};
      var extractedBytes = 0;
      for (final file in archive) {
        if (file.isSymbolicLink) {
          throw BackupException('ZIP 包含符号链接，已拒绝：${file.name}');
        }
        if (!file.isFile) continue;
        if (!names.containsKey(file.name) || files.containsKey(file.name) ||
            (target == null && names[file.name] != file.size)) {
          throw BackupException('ZIP 条目与中央目录不一致：${file.name}');
        }
        final compression = file.compression;
        if (compression != null && compression != CompressionType.none &&
            compression != CompressionType.deflate) {
          throw BackupException('ZIP 使用了不支持的压缩方式：${file.name}');
        }
        if (target == null && file.size > webBackupMaxBytes - extractedBytes) {
          throw const BackupException(_webBackupLimitMessage);
        }
        final limit = file.name == 'manifest.json' ? _maxManifestBytes : _maxFileBytes;
        if (file.size < 0 || file.size > limit) {
          throw BackupException('ZIP 条目超过 ${limit ~/ (1024 * 1024)} MB：${file.name}');
        }
        final output = _BoundedZipOutput(maxBytes: file.size, fileName: file.name);
        try {
          file.decompress(output);
        } on _ZipLimitException catch (error) {
          throw BackupException(error.message);
        } on ArchiveLimitException {
          throw BackupException('ZIP 条目大小与声明不一致：${file.name}');
        } catch (_) {
          throw BackupException('ZIP 条目解压失败：${file.name}');
        }
        if (output.length != file.size) {
          throw BackupException('ZIP 条目大小与声明不一致：${file.name}');
        }
        final bytes = output.getBytes();
        if (target == null) {
          extractedBytes += bytes.length;
          files[file.name] = _ImportEntry.memory(bytes);
        } else {
          final extracted = File('${target.path}/${files.length}');
          await extracted.writeAsBytes(bytes);
          files[file.name] = _ImportEntry.disk(extracted);
        }
      }
      return files;
    } on BackupException {
      rethrow;
    } on FileSystemException {
      throw const BackupException('无法读取或暂存备份，请检查文件和可用空间');
    } catch (_) {
      throw const BackupException('ZIP 无法读取或已损坏');
    }
  }

  Future<BackupImportResult> importBackup(
    List<int> zipBytes, {
    String? password,
  }) async {
    final plan = await prepareImport(zipBytes, password: password);
    try {
      return await plan.commit();
    } finally {
      await plan.dispose();
    }
  }

  Future<void> recoverInterruptedImports() => kIsWeb ? Future<void>.value() : _operation(_recoverUnlocked);

  Future<void> _recoverUnlocked() async {
    final base = Directory('${store.root.path}/$_stagingFolder');
    if (!await base.exists()) return;
    await for (final entry in base.list(followLinks: false)) {
      if (entry is Directory) {
        final session = entry.path.split(Platform.pathSeparator).last;
        if (_activeSessions.contains(session)) continue;
        final journal = File('${base.path}/$session.json');
        Map<String, dynamic>? data;
        if (await journal.exists()) {
          try {
            final decoded = jsonDecode(await journal.readAsString());
            if (decoded is Map) data = Map<String, dynamic>.from(decoded);
          } catch (_) {
            data = null;
          }
        }
        final listed = data?['files'];
        if (listed is List) {
          for (final item in listed) {
            if (item is! Map) continue;
            final finalPath = item['final'];
            final hash = item['hash'];
            if (finalPath is! String ||
                hash is! String ||
                !_assetPathRegExp.hasMatch(finalPath))
              continue;
            final referenced = await store.db.query(
              'assets',
              columns: ['id'],
              where: 'hash = ?',
              whereArgs: [hash],
              limit: 1,
            );
            if (referenced.isEmpty) {
              final file = File('${store.root.path}/$finalPath');
              if (await file.exists()) await file.delete();
            }
          }
        }
        await _deleteTree(entry);
        if (await journal.exists()) await journal.delete();
      } else if (entry is File && entry.path.endsWith('.json')) {
        final name = entry.path.split(Platform.pathSeparator).last;
        final session = name.substring(0, name.length - '.json'.length);
        if (_activeSessions.contains(session)) continue;
        await entry.delete();
      }
    }
  }


  void _validateArchivePath(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.startsWith('\\') ||
        name.contains('\\')) {
      throw BackupException('ZIP 包含非法路径：$name');
    }
    if (RegExp(r'^[A-Za-z]:').hasMatch(name))
      throw BackupException('ZIP 包含绝对路径：$name');
    for (final segment in name.split('/')) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          !_safeSegment.hasMatch(segment)) {
        throw BackupException('ZIP 包含非法路径：$name');
      }
    }
  }

  Future<_Existing> _loadExisting() async {
    final providers = await store.db.query('providers');
    final categories = await store.db.query('categories');
    final prompts = await store.db.query('prompts');
    final tasks = await store.db.query('tasks');
    final assets = await store.db.query('assets');
    final taskAssets = await store.db.query('task_assets');
    final attempts = await store.db.query('attempts');
    final settings = await store.db.query('settings');
    return _Existing(
      providers: providers,
      categories: categories,
      prompts: prompts,
      tasks: tasks,
      assets: assets,
      taskAssets: taskAssets,
      attempts: attempts,
      settings: settings,
    );
  }

  Future<_PreparedImport> _prepareOwn(
    Map<String, dynamic> manifest,
    Map<String, _ImportEntry> files,
    _Existing existing,
  ) async {
    final version = manifest['version'];
    if (version != 1 && version != _formatVersion)
      throw BackupException('本地备份版本不受支持：$version');
    final complete = version == 2;
    final warnings = <String>[];
    if (complete) warnings.add('完整备份包含密钥及错误记录；同名设置、草稿和密钥以备份为准。导入后请重新打开应用。');

    final assetEntries = _list(manifest['assets'], 'assets');
    final assetPlans = <String, _AssetPlan>{};
    final actualAssets = <String, ImageAsset>{};
    final existingById = <String, ImageAsset>{};
    final existingByHash = <String, ImageAsset>{};
    for (final row in existing.assets) {
      try {
        final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
        existingById[asset.id] = asset;
        existingByHash[asset.hash] = asset;
      } catch (_) {
        // Ignore an unreadable local row; it cannot be reused.
      }
    }
    var duplicateAssets = 0;
    for (final raw in assetEntries) {
      final entry = _map(raw, 'assets[]');
      final oldId = _requiredString(entry['id'], 'assets[].id');
      final declaredHash = _requiredString(entry['hash'], 'assets[].hash');
      final declaredPath = _requiredString(entry['path'], 'assets[].path');
      final mime = _requiredString(entry['mime'], 'assets[].mime');
      final expectedSize = _optionalInt(entry['bytes'], 'assets[].bytes');
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(declaredHash))
        throw BackupException('图片哈希格式无效：$declaredHash');
      final extension = _extensionByMime[mime];
      if (extension == null) throw BackupException('不支持的图片格式：$mime');
      if (declaredPath != 'assets/$declaredHash.$extension') {
        throw BackupException('图片路径与哈希或格式不一致：$declaredPath');
      }
      final file = files[declaredPath];
      if (file == null) throw BackupException('导入包缺少图片文件：$declaredPath');
      final size = await file.length();
      if (expectedSize != null && expectedSize != size) {
        throw BackupException('图片大小与记录不一致：$declaredPath');
      }
      final computed = await file.hash();
      if (computed != declaredHash)
        throw BackupException('图片内容哈希不匹配：$declaredPath');
      await _validateImage(await file.readAsBytes(), mime, declaredPath);
      if (assetPlans.containsKey(oldId))
        throw BackupException('备份包含重复图片 ID：$oldId');
      final sameId = existingById[oldId];
      if (sameId != null && sameId.hash != computed) {
        throw BackupException('图片 ID $oldId 与本地内容冲突，导入已停止，未覆盖本地图片');
      }
      final existingAsset = existingByHash[computed] ?? sameId;
      final actual =
          existingAsset ??
          ImageAsset(
            id: computed,
            path: declaredPath,
            mime: mime,
            hash: computed,
            bytes: size,
            remoteUrl: entry['remoteUrl'] as String?,
            width: _optionalInt(entry['width'], 'assets[].width'),
            height: _optionalInt(entry['height'], 'assets[].height'),
          );
      final plan = _AssetPlan(
        oldId: oldId,
        asset: actual,
        file: existingAsset == null ? file : null,
      );
      assetPlans[oldId] = plan;
      actualAssets[oldId] = actual;
      if (existingAsset != null) {
        duplicateAssets++;
      }
    }

    final providerMaps = _mapProviders(
      _list(manifest['providers'], 'providers'),
      existing,
    );
    final categoryMaps = _mapCategories(
      _list(manifest['categories'], 'categories'),
      existing,
    );
    final promptMaps = _mapPrompts(
      _list(manifest['prompts'], 'prompts'),
      existing,
    );

    final tasks = <_IncomingTask>[];
    final rawTaskRows = <String, Map<String, Object?>>{};
    final relationsByTask = <String, List<_Relation>>{};
    for (final raw in _list(manifest['taskAssets'], 'taskAssets')) {
      final row = _map(raw, 'taskAssets[]');
      final taskId = _requiredString(row['task_id'], 'taskAssets[].task_id');
      final assetId = _requiredString(row['asset_id'], 'taskAssets[].asset_id');
      final role = _requiredString(row['role'], 'taskAssets[].role');
      if (!_relationRoles.contains(role))
        throw BackupException('任务图片关系角色无效：$role');
      final position = _requiredInt(row['position'], 'taskAssets[].position');
      final attempt = _requiredInt(row['attempt'], 'taskAssets[].attempt');
      if (position < 0 || attempt < 0) throw BackupException('任务图片关系位置无效');
      final relation = _Relation(
        taskId: taskId,
        assetId: assetId,
        role: role,
        position: position,
        attempt: attempt,
      );
      final list = relationsByTask.putIfAbsent(taskId, () => []);
      if (list.any(
        (r) => r.assetId == assetId && r.role == role && r.attempt == attempt && r.position == position,
      )) {
        throw BackupException('备份包含重复的任务图片关系：$taskId/$assetId/$role/$attempt');
      }
      list.add(relation);
    }
    final attemptsByTask = <String, List<_Attempt>>{};
    for (final raw in _list(manifest['attempts'], 'attempts')) {
      final row = _map(raw, 'attempts[]');
      final taskId = _requiredString(row['task_id'], 'attempts[].task_id');
      final attempt = _Attempt(
        taskId: taskId,
        number: _requiredInt(row['number'], 'attempts[].number'),
        startedAt: _requiredString(row['started_at'], 'attempts[].started_at'),
        endedAt: row['ended_at'] as String?,
        metadata: _requiredString(row['metadata'], 'attempts[].metadata'),
        error: row['error'] as String?,
      );
      _parseDate(attempt.startedAt, 'attempts[].started_at');
      if (attempt.endedAt != null)
        _parseDate(attempt.endedAt!, 'attempts[].ended_at');
      try {
        jsonDecode(attempt.metadata);
      } catch (_) {
        throw BackupException('任务尝试元数据不是有效 JSON：$taskId/${attempt.number}');
      }
      final list = attemptsByTask.putIfAbsent(taskId, () => []);
      if (list.any((a) => a.number == attempt.number)) {
        throw BackupException('备份包含重复的任务尝试：$taskId/${attempt.number}');
      }
      list.add(attempt);
    }

    // 处理断点：后处理失败的任务恢复后应只重跑本地处理，不再重新收费。
    final pipelineByTask = <String, _PipelineRow>{};
    final pipelineRaw = manifest['pipelineState'];
    if (pipelineRaw is List) {
      for (final raw in pipelineRaw) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final taskId = row['task_id'];
        if (taskId is! String) continue;
        final stage = row['stage'];
        if (stage != 'preprocess' && stage != 'postprocess') continue;
        final position = row['position'];
        final attempt = row['attempt'];
        final step = row['step'];
        if (position is! int || attempt is! int || step is! int) continue;
        if (attempt < 0 || step < 0 || position < 0) continue;
        final expected = row['expected'];
        pipelineByTask[taskId] = _PipelineRow(
          taskId: taskId,
          stage: stage as String,
          position: position,
          attempt: attempt,
          step: step,
          sourceAssetId: row['source_asset_id'] as String?,
          message: row['message'] as String?,
          expected: expected is int ? expected : null,
          updatedAt:
              row['updated_at'] as String? ??
              DateTime.now().toUtc().toIso8601String(),
        );
      }
    }
    for (final raw in _list(manifest['tasks'], 'tasks')) {
      final row = _map(raw, 'tasks[]');
      final id = _requiredString(row['id'], 'tasks[].id');
      if (rawTaskRows.containsKey(id)) throw BackupException('备份包含重复任务 ID：$id');
      final inputRaw = row['input'];
      final input = inputRaw is String
          ? decodeObject(inputRaw)
          : _map(inputRaw, 'tasks[].input');
      GenerationInput parsed;
      try {
        parsed = GenerationInput.fromJson(input);
      } catch (_) {
        throw BackupException('任务 $id 的输入无效');
      }
      if (parsed.taskId != id) throw BackupException('任务 $id 的输入任务 ID 不一致');
      final status = _requiredString(row['status'], 'tasks[].status');
      final importedStatus = status == 'queued' || status == 'running'
          ? 'interrupted'
          : status;
      if (importedStatus != status) {
        warnings.add('本地备份中有排队或执行中的任务，已恢复为“已中断”，不会自动继续执行。');
      }
      if (!_taskStatuses.contains(status))
        throw BackupException('任务状态无效：$status');
      final createdAt = _requiredString(
        row['created_at'],
        'tasks[].created_at',
      );
      _parseDate(createdAt, 'tasks[].created_at');
      final favorite = _requiredInt(row['favorite'], 'tasks[].favorite');
      if (favorite != 0 && favorite != 1)
        throw BackupException('任务收藏标记无效：$favorite');
      final attempt = _requiredInt(row['attempt'], 'tasks[].attempt');
      if (attempt < 0) throw BackupException('任务尝试次数无效：$attempt');
      final categoryId = row['category_id'] as String?;
      final deletedAt = row['deleted_at'] as String?;
      if (deletedAt != null) _parseDate(deletedAt, 'tasks[].deleted_at');
      final relations = relationsByTask[id] ?? const <_Relation>[];
      for (final relation in relations) {
        _requireAsset(relation.assetId, assetPlans, existingById);
      }
      for (final asset in [parsed.mask, parsed.markup, ...parsed.references]) {
        if (asset != null) _requireAsset(asset.id, assetPlans, existingById);
      }
      // 预处理后的有效输入（派生参考图）也要恢复，否则重试会重复变换。
      GenerationInput? original;
      final originalRaw = row['original_input'];
      if (originalRaw is String && originalRaw.isNotEmpty) {
        try {
          original = GenerationInput.fromJson(decodeObject(originalRaw));
        } on Object {
          warnings.add('任务 $id 的本地处理快照无法解析，已忽略。');
        }
      }
      if (original != null) {
        final ids = [
          original.mask?.id,
          original.markup?.id,
          for (final asset in original.references) asset.id,
        ];
        final missing = ids.any(
          (assetId) =>
              assetId != null &&
              !assetPlans.containsKey(assetId) &&
              !existingById.containsKey(assetId),
        );
        if (missing) {
          original = null;
          warnings.add('任务 $id 的本地处理快照引用了缺失的图片，已忽略。');
        }
      }
      final sourceRow = <String, Object?>{
        'id': id,
        'input': input,
        'status': importedStatus,
        'created_at': createdAt,
        'favorite': favorite,
        'category_id': categoryId,
        'deleted_at': deletedAt,
        'error': row['error'] as String?,
        'attempt': attempt,
      };
      rawTaskRows[id] = sourceRow;
      final incoming = _IncomingTask(
        id: id,
        prompt: parsed.prompt,
        params: parsed.params,
        referenceIds: parsed.references.map((a) => a.id).toList(),
        maskId: parsed.mask?.id,
        markupId: parsed.markup?.id,
        parentTaskId: parsed.parentTaskId,
        parentAssetId: parsed.parentAssetId,
        providerId: parsed.provider.id,
        providerSnapshot: parsed.provider.toJson(),
        originalInput: original,
        pipeline: pipelineByTask[id],
        status: importedStatus,
        createdAt: createdAt,
        favorite: favorite,
        categoryId: categoryId,
        deletedAt: deletedAt,
        error: sourceRow['error'] as String?,
        attempt: attempt,
        relations: relations.toList(),
        attempts: (attemptsByTask[id] ?? const <_Attempt>[]).toList(),
        signature: _ownSignature(
          sourceRow,
          relations,
          attemptsByTask[id] ?? const [],
        ),
        source: 'local-v$version',
        upstreamVersion: null,
        compatMeta: null,
        preprocessors: parsed.preprocessors,
        postprocessors: parsed.postprocessors,
      );
      tasks.add(incoming);
    }

    final declared = manifest['pluginDependencies'];
    if (declared is List && declared.isNotEmpty) {
      final installed = {
        for (final plugin in kIsWeb ? PluginManager.builtinPlugins : await PluginManager(store).list())
          '${plugin.id}@${plugin.version}',
      };
      for (final raw in declared) {
        if (raw is! Map) continue;
        final id = raw['pluginId'];
        final version = raw['version'];
        if (id is! String || id.isEmpty) {
          // 只记录了适配器 ID（旧备份或元数据缺失），不猜包 ID。
          final adapterId = raw['adapterId'];
          if (adapterId is String && adapterId.isNotEmpty) {
            warnings.add(
              '备份使用未知适配器「$adapterId@${version ?? ''}」，本机找不到对应插件，相关任务需先安装该适配器才能重新生成。',
            );
          }
          continue;
        }
        if (installed.contains('$id@${version ?? ''}')) continue;
        warnings.add(
          '备份依赖插件「$id@${version ?? ''}」，当前未安装或版本不符；相关任务需先安装该插件才能重新生成。',
        );
      }
    }
    final taskMaps = _mapTasks(
      tasks,
      existing,
      existing.taskAssets,
      existing.attempts,
    );
    final settings = _mapOwnSettings(
      _map(manifest['settings'], 'settings'),
      existing,
      providerMaps,
      actualAssets,
      complete: complete,
      taskIds: taskMaps.ids,
    );
    final credentials = <String, String>{};
    final errorRows = <Map<String, Object?>>[];
    if (complete) {
      for (final entry in _map(
        manifest['credentials'],
        'credentials',
      ).entries) {
        final value = entry.value;
        if (entry.key.isEmpty || value is! String)
          throw const BackupException('备份密钥字段无效');
        final providerId = entry.key.startsWith('provider:')
            ? entry.key.substring(9)
            : null;
        final key = providerId == null
            ? entry.key
            : 'provider:${providerMaps.idMap[providerId] ?? providerId}';
        credentials[key] = value;
      }
      final existingErrors = {
        for (final row in await store.db.query('errors'))
          row['id'] as String: row,
      };
      final seenErrorIds = <String>{};
      for (final raw in _list(manifest['errors'], 'errors')) {
        final entry = _map(raw, 'errors[]');
        final id = _requiredString(entry['id'], 'errors[].id');
        if (!seenErrorIds.add(id)) throw const BackupException('备份包含重复错误记录 ID');
        final taskId = _optionalString(entry['task_id'], 'errors[].task_id');
        final createdAt = _requiredString(
          entry['created_at'],
          'errors[].created_at',
        );
        _parseDate(createdAt, 'errors[].created_at');
        final row = <String, Object?>{
          'id': id,
          'task_id': taskId == null ? null : (taskMaps.ids[taskId] ?? taskId),
          'message':
              _optionalString(entry['message'], 'errors[].message') ??
              (throw const BackupException('错误记录缺少 message')),
          'created_at': createdAt,
        };
        final previous = existingErrors[id];
        if (previous != null &&
            row.keys.every((key) => row[key] == previous[key]))
          continue;
        if (previous != null) row['id'] = newId();
        errorRows.add(row);
      }
      warnings.add(
        '恢复 ${credentials.length} 项安全存储数据、${errorRows.length} 条错误记录。',
      );
    }
    final prepared = await _buildPrepared(
      format: '本地备份 v$version',
      existing: existing,
      tasks: tasks,
      assetPlans: assetPlans,
      actualAssets: actualAssets,
      providerMaps: providerMaps,
      categoryMaps: categoryMaps,
      promptMaps: promptMaps,
      taskMaps: taskMaps,
      settings: settings.rows,
      settingsAdded: settings.added,
      settingsSkipped: settings.skipped,
      duplicateAssets: duplicateAssets,
      warnings: warnings,
      credentials: credentials,
      errors: errorRows,
      replaceSettings: complete,
    );
    return prepared;
  }

  Future<_PreparedImport> _prepareUpstream(
    Map<String, dynamic> manifest,
    Map<String, _ImportEntry> files,
    _Existing existing,
  ) async {
    final version = _requiredInt(manifest['version'], 'version');
    if (version < 6 || version > 9) {
      throw BackupException('备份版本不受支持，只支持上游 v6 至 v9 或本地 v1：$version');
    }
    final warnings = <String>[];
    final persisted = manifest['persistedState'] is Map
        ? Map<String, dynamic>.from(manifest['persistedState'] as Map)
        : const <String, dynamic>{};
    final settings = persisted['settings'] is Map
        ? Map<String, dynamic>.from(persisted['settings'] as Map)
        : (manifest['settings'] is Map
              ? Map<String, dynamic>.from(manifest['settings'] as Map)
              : <String, dynamic>{});
    final providersRaw =
        persisted['providers'] is List &&
            (persisted['providers'] as List).isNotEmpty
        ? persisted['providers'] as List
        : (manifest['providers'] is List
              ? manifest['providers'] as List
              : const <dynamic>[]);
    final categoriesRaw =
        persisted['categories'] is List &&
            (persisted['categories'] as List).isNotEmpty
        ? persisted['categories'] as List
        : (manifest['categories'] is List
              ? manifest['categories'] as List
              : const <dynamic>[]);
    final promptsRaw =
        persisted['promptLibrary'] is List &&
            (persisted['promptLibrary'] as List).isNotEmpty
        ? persisted['promptLibrary'] as List
        : (manifest['promptLibrary'] is List
              ? manifest['promptLibrary'] as List
              : const <dynamic>[]);

    final providers = <ProviderConfig>[];
    final providerKeys = <String, String>{};
    final providerIds = <String>{};
    for (final raw in providersRaw) {
      final entry = _map(raw, 'providers[]');
      final config = _providerFromUpstream(entry);
      if (!providerIds.add(config.id))
        throw BackupException('备份包含重复供应商 ID：${config.id}');
      providers.add(config);
      final key = entry['apiKey'];
      if (key is String && key.trim().isNotEmpty)
        providerKeys[config.id] = key.trim();
      if (entry['apiKey'] != null && entry['apiKey'] is! String) {
        warnings.add('已忽略供应商 ${config.name} 中格式无效的密钥字段');
      }
    }
    if (providers.isEmpty) {
      providers.add(_fallbackProvider(settings));
      warnings.add('上游备份没有供应商配置，已创建一个无密钥的默认配置，导入后请补填。');
    }
    final providerMaps = _mapProviders(
      providers.map((p) => p.toJson()).toList(),
      existing,
    );
    final providerFallbackId =
        providerMaps.idMap[providers.first.id] ?? providers.first.id;

    final categories = <Map<String, dynamic>>[];
    for (final raw in categoriesRaw) {
      final entry = _map(raw, 'categories[]');
      categories.add({
        'id': _requiredString(entry['id'], 'categories[].id'),
        'name': _requiredString(entry['name'], 'categories[].name'),
      });
    }
    final categoryMaps = _mapCategories(categories, existing);
    final prompts = <Map<String, dynamic>>[];
    for (final raw in promptsRaw) {
      final entry = _map(raw, 'promptLibrary[]');
      prompts.add({
        'id': _requiredString(entry['id'], 'promptLibrary[].id'),
        'title': _requiredString(entry['title'], 'promptLibrary[].title'),
        'content': _requiredString(entry['content'], 'promptLibrary[].content'),
        'updated_at': _upstreamTime(
          entry['updatedAt'],
          'promptLibrary[].updatedAt',
        ),
      });
    }
    final promptMaps = _mapPrompts(prompts, existing);

    final paramsRaw = persisted['params'] is Map
        ? Map<String, dynamic>.from(persisted['params'] as Map)
        : (manifest['params'] is Map
              ? Map<String, dynamic>.from(manifest['params'] as Map)
              : <String, dynamic>{});

    final imageFiles = _map(manifest['imageFiles'], 'imageFiles');
    final assetPlans = <String, _AssetPlan>{};
    final actualAssets = <String, ImageAsset>{};
    final existingById = <String, ImageAsset>{};
    final existingByHash = <String, ImageAsset>{};
    for (final row in existing.assets) {
      try {
        final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
        existingById[asset.id] = asset;
        existingByHash[asset.hash] = asset;
      } catch (_) {
        // Ignore an unreadable local row.
      }
    }

    final rawTasks = _list(manifest['tasks'], 'tasks');
    final taskIds = <String>{};
    final incoming = <_IncomingTask>[];
    final referencedIds = <String>{};
    final remoteIds = <String>{};
    final localImages = <String, _ImportEntry>{};
    final localImageMeta = <String, Map<String, dynamic>>{};

    for (final taskRaw in rawTasks) {
      final row = _map(taskRaw, 'tasks[]');
      final id = _requiredString(row['id'], 'tasks[].id');
      if (!taskIds.add(id)) throw BackupException('备份包含重复任务 ID：$id');
      final statusRaw = _requiredString(row['status'], 'tasks[].status');
      final status = _upstreamStatus(statusRaw, row, warnings);
      final createdAt = _upstreamTime(row['createdAt'], 'tasks[].createdAt');
      final prompt = row['prompt'] as String? ?? '';
      final taskParams = _paramsFromUpstream(
        _map(row['params'], 'tasks[].params'),
      );
      final inputIds = _stringList(
        row['inputImageIds'],
        'tasks[].inputImageIds',
      );
      final outputIds = _stringList(
        row['outputImages'],
        'tasks[].outputImages',
      );
      final maskId = _optionalString(
        row['editMaskImageId'],
        'tasks[].editMaskImageId',
      );
      final markupId = _optionalString(
        row['editMarkupImageId'],
        'tasks[].editMarkupImageId',
      );
      final sourceId = _optionalString(
        row['editSourceImageId'],
        'tasks[].editSourceImageId',
      );
      final parentTaskId = _optionalString(
        row['parentTaskId'],
        'tasks[].parentTaskId',
      );
      final categoryId = _optionalString(
        row['categoryId'],
        'tasks[].categoryId',
      );
      final rawProviderId = _optionalString(
        row['providerId'],
        'tasks[].providerId',
      );
      final providerId =
          rawProviderId != null && providerMaps.idMap.containsKey(rawProviderId)
          ? rawProviderId
          : providerFallbackId;
      if (rawProviderId != null && providerId != rawProviderId) {
        warnings.add('任务 $id 引用了未知供应商，已改用默认供应商。');
      }
      final favorite = row['isFavorite'] == true ? 1 : 0;
      final deletedAt = row['deletedAt'] == null
          ? null
          : _upstreamTime(row['deletedAt'], 'tasks[].deletedAt');
      final finishedAt = row['finishedAt'] == null
          ? null
          : _upstreamTime(row['finishedAt'], 'tasks[].finishedAt');
      _validateEditSelection(row['editSelection']);
      referencedIds.addAll(inputIds);
      referencedIds.addAll(outputIds);
      if (maskId != null) referencedIds.add(maskId);
      if (markupId != null) referencedIds.add(markupId);
      if (sourceId != null) referencedIds.add(sourceId);

      final relations = <_Relation>[
        for (var i = 0; i < inputIds.length; i++)
          _Relation(
            taskId: id,
            assetId: inputIds[i],
            role: 'input',
            position: i,
            attempt: 0,
          ),
        if (maskId != null)
          _Relation(
            taskId: id,
            assetId: maskId,
            role: 'mask',
            position: 0,
            attempt: 0,
          ),
        if (markupId != null)
          _Relation(
            taskId: id,
            assetId: markupId,
            role: 'markup',
            position: 0,
            attempt: 0,
          ),
        for (var i = 0; i < outputIds.length; i++)
          _Relation(
            taskId: id,
            assetId: outputIds[i],
            role: 'output',
            position: i,
            attempt: 0,
          ),
      ];
      final signature = _upstreamSignature(
        row,
        status,
        createdAt,
        taskParams,
        inputIds,
        outputIds,
      );
      final compat = <String, dynamic>{
        'source': 'upstream',
        'version': version,
        'importSignature': signature,
      };
      for (final pair in {
        'taskKind': row['taskKind'],
        'responseMeta': row['responseMeta'],
        'elapsed': row['elapsed'],
        'editSelection': row['editSelection'],
        'isAborted': row['isAborted'],
        'providerName': row['providerName'],
        'categoryName': row['categoryName'],
      }.entries) {
        if (pair.value != null) compat[pair.key] = _sanitize(pair.value);
      }
      final error = row['error'] as String?;
      final attempt = _Attempt(
        taskId: id,
        number: 0,
        startedAt: createdAt,
        endedAt: statusRaw == 'running' ? null : finishedAt,
        metadata: _metadataJson(compat),
        error: error,
      );
      final sourceRow = <String, Object?>{
        'id': id,
        'status': status,
        'created_at': createdAt,
        'favorite': favorite,
        'category_id': categoryId,
        'deleted_at': deletedAt,
        'error': status == 'interrupted' && (error == null || error.isEmpty)
            ? '任务执行已中断，已保留完成的图片，可手动重试'
            : error,
        'attempt': 0,
      };
      incoming.add(
        _IncomingTask(
          id: id,
          prompt: prompt,
          params: taskParams,
          referenceIds: inputIds,
          maskId: maskId,
          markupId: markupId,
          parentTaskId: parentTaskId,
          parentAssetId: sourceId,
          providerId: providerId,
          providerSnapshot: const {},
          status: status,
          createdAt: createdAt,
          favorite: favorite,
          categoryId: categoryId,
          deletedAt: deletedAt,
          error: sourceRow['error'] as String?,
          attempt: 0,
          relations: relations,
          attempts: [attempt],
          signature: signature,
          source: 'upstream-v$version',
          upstreamVersion: version,
          compatMeta: compat,
        ),
      );
    }

    // Read image entries only after task references are known.
    for (final entry in imageFiles.entries) {
      final imageId = entry.key;
      final meta = _map(entry.value, 'imageFiles["$imageId"]');
      final path = meta['path'] as String?;
      final url = meta['url'] as String?;
      if ((path == null || path.isEmpty) && (url == null || url.isEmpty)) {
        throw BackupException('导入包图片条目既没有路径也没有 URL：$imageId');
      }
      final contentHash = meta['contentHash'];
      if (contentHash != null && contentHash is! String) {
        throw BackupException('图片 $imageId 的内容哈希字段无效');
      }
      if (path != null && path.isNotEmpty) {
        final file = files[path];
        if (file == null) throw BackupException('导入包缺少图片文件：$path');
        if (contentHash is String && contentHash.isNotEmpty &&
            contentHash.toLowerCase() != await file.hash()) {
          throw BackupException('图片内容哈希不匹配：$path');
        }
        localImages[imageId] = file;
        localImageMeta[imageId] = meta;
      } else {
        remoteIds.add(imageId);
      }
    }

    for (final id in referencedIds) {
      if (existingById.containsKey(id)) continue;
      if (localImages.containsKey(id)) continue;
      if (remoteIds.contains(id)) {
        throw BackupException('上游备份中的远程图片未包含文件，无法离线导入：$id');
      }
      throw BackupException('导入包缺少被任务引用的图片条目：$id');
    }

    var duplicateAssets = 0;
    for (final id in referencedIds) {
      if (!localImages.containsKey(id)) {
        final local = existingById[id];
        if (local != null) {
          assetPlans[id] = _AssetPlan(oldId: id, asset: local, file: null);
          actualAssets[id] = local;
        }
        continue;
      }
      final meta = localImageMeta[id]!;
      final file = localImages[id]!;
      final size = await file.length();
      final mime = _upstreamMime(meta, id);
      await _validateImage(await file.readAsBytes(), mime, id);
      final extension = _extensionByMime[mime];
      if (extension == null) throw BackupException('图片 $id 的格式不受支持：$mime');
      final computed = await file.hash();
      final sameId = existingById[id];
      if (sameId != null && sameId.hash != computed) {
        throw BackupException('图片 ID $id 与本地内容冲突，导入已停止，未覆盖本地图片');
      }
      final existingAsset = existingByHash[computed] ?? sameId;
      final width = _optionalInt(meta['width'], 'imageFiles["$id"].width');
      final height = _optionalInt(meta['height'], 'imageFiles["$id"].height');
      if ((width != null && width < 0) || (height != null && height < 0)) {
        throw BackupException('图片尺寸无效：$id');
      }
      final declaredSize = _optionalInt(
        meta['byteSize'],
        'imageFiles["$id"].byteSize',
      );
      if (declaredSize != null && declaredSize != size) {
        throw BackupException('图片大小与记录不一致：$id');
      }
      final actual =
          existingAsset ??
          ImageAsset(
            id: computed,
            path: 'assets/$computed.$extension',
            mime: mime,
            hash: computed,
            bytes: size,
            remoteUrl: null,
            width: width,
            height: height,
          );
      assetPlans[id] = _AssetPlan(
        oldId: id,
        asset: actual,
        file: existingAsset == null ? file : null,
      );
      actualAssets[id] = actual;
      if (existingAsset != null) {
        duplicateAssets++;
      }
    }
    final skippedImages = localImages.keys
        .where((id) => !referencedIds.contains(id))
        .length;
    if (skippedImages > 0) warnings.add('跳过 $skippedImages 张未被任何任务引用的图片。');
    if (remoteIds.isNotEmpty)
      warnings.add('忽略 ${remoteIds.length} 个未包含文件的上游远程图片条目。');
    if (providerKeys.isNotEmpty) {
      warnings.add('上游备份包含 ${providerKeys.length} 个明文密钥，将在提交后写入系统安全存储。');
    }

    final taskMapsFinal = _mapTasks(
      incoming,
      existing,
      existing.taskAssets,
      existing.attempts,
    );
    final draftSettings = <Map<String, Object?>>[];
    var settingsAdded = 0;
    var settingsSkipped = 0;
    final existingSettings = existing.settings
        .map((r) => r['key'] as String)
        .toSet();
    void addDraft(String key, Object? value) {
      if (existingSettings.contains(key) || value == null) {
        if (existingSettings.contains(key)) settingsSkipped++;
        return;
      }
      draftSettings.add({'key': key, 'value': jsonEncode(value)});
      settingsAdded++;
    }

    final activeProvider =
        persisted['activeProviderId'] ?? manifest['activeProviderId'];
    final draft = <String, dynamic>{};
    if (paramsRaw.isNotEmpty)
      draft['params'] = _paramsFromUpstream(paramsRaw).toJson();
    if (activeProvider is String) {
      draft['providerId'] =
          providerMaps.idMap[activeProvider] ?? activeProvider;
    }
    if (draft.isNotEmpty) addDraft('draft', _sanitize(draft));
    final activeCategory =
        persisted['activeCategoryFilter'] ?? manifest['activeCategoryFilter'];
    if (activeCategory is String) {
      addDraft(
        'upstream.activeCategoryFilter',
        categoryMaps.idMap[activeCategory] ?? activeCategory,
      );
    }
    final cleanSettings = Map<String, dynamic>.from(settings)
      ..remove('apiKey')
      ..['requestMode'] = 'direct';
    if (cleanSettings.isNotEmpty)
      addDraft('upstream.settings', _sanitize(cleanSettings));

    final mappedKeys = <String, String>{
      for (final entry in providerKeys.entries)
        providerMaps.idMap[entry.key] ?? entry.key: entry.value,
    };
    final prepared = await _buildPrepared(
      format: '上游备份 v$version',
      existing: existing,
      tasks: incoming,
      assetPlans: assetPlans,
      actualAssets: actualAssets,
      providerMaps: providerMaps,
      categoryMaps: categoryMaps,
      promptMaps: promptMaps,
      taskMaps: taskMapsFinal,
      settings: draftSettings,
      settingsAdded: settingsAdded,
      settingsSkipped: settingsSkipped,
      duplicateAssets: duplicateAssets,
      warnings: warnings,
      credentials: {
        for (final entry in mappedKeys.entries)
          'provider:${entry.key}': entry.value,
      },
    );
    return prepared;
  }

  /// 只记录任务依赖的插件，不打包插件代码。
  static List<Map<String, dynamic>> _pluginDependencies(
    List<Map<String, Object?>> tasks,
    List<InstalledPlugin> installed,
  ) {
    const builtIn = {'images', 'responses', 'wavespeed', 'evolink'};
    // 适配器 ID 不等于插件包 ID：只用已安装清单的元数据反查，不加载也不执行脚本。
    final owners = <String, String>{};
    for (final plugin in installed) {
      for (final spec in plugin.manifest?.providers ?? const []) {
        owners[spec.id] = plugin.id;
      }
    }
    final found = <String, Map<String, dynamic>>{};
    void note(
      String? pluginId,
      String? adapterId,
      String? version,
      String kind,
    ) {
      if ((pluginId ?? adapterId ?? '').isEmpty) return;
      final entry = found.putIfAbsent(
        '${pluginId ?? 'unknown:$adapterId'}@${version ?? ''}',
        () => {
          'pluginId': pluginId,
          if (adapterId != null) 'adapterId': adapterId,
          'version': version,
          'kinds': <String>{},
        },
      );
      (entry['kinds'] as Set<String>).add(kind);
    }

    for (final row in tasks) {
      final GenerationInput input;
      try {
        input = GenerationInput.fromJson(decodeObject(row['input'] as String));
      } on Object {
        continue;
      }
      final adapterId = input.provider.adapterId;
      if (!builtIn.contains(adapterId) && !adapterId.startsWith('local.')) {
        note(
          owners[adapterId],
          adapterId,
          input.provider.adapterVersion,
          'provider',
        );
      }
      for (final step in [...input.preprocessors, ...input.postprocessors]) {
        note(step.pluginId, null, step.version, 'processor');
      }
    }
    return [
      for (final entry in found.values)
        {...entry, 'kinds': (entry['kinds'] as Set<String>).toList()},
    ];
  }

  Future<_PreparedImport> _buildPrepared({
    required String format,
    required _Existing existing,
    required List<_IncomingTask> tasks,
    required Map<String, _AssetPlan> assetPlans,
    required Map<String, ImageAsset> actualAssets,
    required _ProviderMaps providerMaps,
    required _CategoryMaps categoryMaps,
    required _PromptMaps promptMaps,
    required _TaskMaps taskMaps,
    required List<Map<String, Object?>> settings,
    required int settingsAdded,
    required int settingsSkipped,
    required int duplicateAssets,
    required List<String> warnings,
    required Map<String, String> credentials,
    List<Map<String, Object?>> errors = const [],
    bool replaceSettings = false,
  }) async {
    final taskRows = <Map<String, Object?>>[];
    final taskAssetRows = <Map<String, Object?>>[];
    final attemptRows = <Map<String, Object?>>[];
    final pipelineRows = <Map<String, Object?>>[];
    var skipped = 0;
    var remapped = 0;
    for (final task in tasks) {
      final newId = taskMaps.ids[task.id]!;
      if (taskMaps.duplicates.contains(task.id)) {
        skipped++;
        continue;
      }
      if (newId != task.id) remapped++;
      final providerId = task.providerId == null
          ? null
          : (providerMaps.idMap[task.providerId] ?? task.providerId!);
      final providerJson = task.source == 'local-v2'
          ? {...task.providerSnapshot, 'id': ?providerId}
          : providerId == null
          ? task.providerSnapshot
          : (providerMaps.configs[providerId] ??
                (task.providerSnapshot.isNotEmpty &&
                        task.providerSnapshot['id'] == providerId
                    ? task.providerSnapshot
                    : {'id': providerId}));
      final input = <String, dynamic>{
        'taskId': newId,
        'provider': providerJson,
        'prompt': task.prompt,
        'params': task.params.toJson(),
        'references': [
          for (final id in task.referenceIds)
            _assetFor(id, assetPlans, actualAssets).toJson(),
        ],
        'mask': task.maskId == null
            ? null
            : _assetFor(task.maskId!, assetPlans, actualAssets).toJson(),
        'markup': task.markupId == null
            ? null
            : _assetFor(task.markupId!, assetPlans, actualAssets).toJson(),
        'parentTaskId': task.parentTaskId == null
            ? null
            : (taskMaps.ids[task.parentTaskId] ?? task.parentTaskId),
        'parentAssetId': task.parentAssetId == null
            ? null
            : _assetFor(task.parentAssetId!, assetPlans, actualAssets).id,
        'preprocessors': [
          for (final step in task.preprocessors)
            _remapStep(step, assetPlans, actualAssets).toJson(),
        ],
        'postprocessors': [
          for (final step in task.postprocessors)
            _remapStep(step, assetPlans, actualAssets).toJson(),
        ],
      };
      taskRows.add({
        'id': newId,
        'input': jsonEncode(input),
        'status': task.status,
        'created_at': task.createdAt,
        'favorite': task.favorite,
        'category_id': task.categoryId == null
            ? null
            : (categoryMaps.idMap[task.categoryId] ?? task.categoryId),
        'deleted_at': task.deletedAt,
        'error': task.error,
        'attempt': task.attempt,
        'original_input': _effectiveInputJson(
          task,
          newId,
          providerJson,
          assetPlans,
          actualAssets,
          taskMaps,
        ),
      });
      for (final relation in task.relations) {
        final asset = _assetFor(relation.assetId, assetPlans, actualAssets);
        taskAssetRows.add({
          'task_id': newId,
          'asset_id': asset.id,
          'role': relation.role,
          'position': relation.position,
          'attempt': relation.attempt,
        });
      }
      for (final attempt in task.attempts) {
        attemptRows.add({
          'task_id': newId,
          'number': attempt.number,
          'started_at': attempt.startedAt,
          'ended_at': attempt.endedAt,
          'metadata': attempt.metadata,
          'error': attempt.error,
        });
      }
      final pipeline = task.pipeline;
      if (pipeline != null) {
        final source = pipeline.sourceAssetId;
        pipelineRows.add({
          'task_id': newId,
          'stage': pipeline.stage,
          'position': pipeline.position,
          'attempt': pipeline.attempt,
          'step': pipeline.step,
          'source_asset_id':
              source == null ||
                  !assetPlans.containsKey(source) &&
                      !actualAssets.containsKey(source)
              ? null
              : _assetFor(source, assetPlans, actualAssets).id,
          'message': pipeline.message,
          'expected': pipeline.expected,
          'updated_at': pipeline.updatedAt,
        });
      }
    }

    final assetRows = <Map<String, Object?>>[];
    final staged = <_StagedAsset>[];
    final seenHashes = <String>{};
    for (final plan in assetPlans.values) {
      final asset = plan.asset;
      if (!seenHashes.add(asset.id)) continue;
      final file = plan.file;
      if (file != null) {
        assetRows.add({
          'id': asset.id,
          'hash': asset.hash,
          'data': jsonEncode(asset.toJson()),
        });
        staged.add(_StagedAsset(asset: asset, file: file));
      }
    }

    final preview = BackupImportPreview(
      format: format,
      tasks: taskRows.length,
      duplicateTasks: skipped,
      remappedTasks: remapped,
      assets: staged.length,
      duplicateAssets: duplicateAssets,
      providersAdded: providerMaps.added.length,
      providersMerged: providerMaps.merged,
      categoriesAdded: categoryMaps.added.length,
      categoriesMerged: categoryMaps.merged,
      promptsAdded: promptMaps.added.length,
      promptsMerged: promptMaps.merged,
      settingsAdded: settingsAdded,
      settingsSkipped: settingsSkipped,
      warnings: warnings,
    );
    return _PreparedImport(
      preview: preview,
      sessionId: newId(),
      providers: providerMaps.added,
      assets: assetRows,
      categories: categoryMaps.added,
      prompts: promptMaps.added,
      settings: settings,
      tasks: taskRows,
      taskAssets: taskAssetRows,
      attempts: attemptRows,
      pipeline: pipelineRows,
      stagedAssets: staged,
      credentials: {
        for (final entry in credentials.entries)
          if (!entry.key.startsWith('provider:'))
            entry.key: entry.value
          else if (providerMaps.configs[entry.key.substring(9)]?['baseUrl'] case final String address)
            entry.key: StudioStore.bindProviderKey(address, entry.value),
      },
      errors: errors,
      replaceSettings: replaceSettings,
      warnings: warnings,
    );
  }

  _ProviderMaps _mapProviders(List<dynamic> rawProviders, _Existing existing) {
    final result = _ProviderMaps();
    final existingById = <String, ProviderConfig>{};
    final existingIds = <String>{};
    for (final row in existing.providers) {
      existingIds.add(row['id'] as String);
      try {
        final config = ProviderConfig.fromJson(
          decodeObject(row['config'] as String),
        );
        existingById[config.id] = config;
      } catch (_) {
        // Keep the id collision guard even when the local row is unreadable.
      }
    }
    final incomingIds = <String>{};
    for (final raw in rawProviders) {
      final entry = _map(raw, 'providers[]');
      final id = _requiredString(entry['id'], 'providers[].id');
      if (!incomingIds.add(id)) throw BackupException('备份包含重复供应商 ID：$id');
      ProviderConfig config;
      try {
        config = ProviderConfig.fromJson(entry);
      } catch (_) {
        throw BackupException('供应商配置无效：$id');
      }
      final validation = config.validate();
      if (validation != null) throw BackupException('供应商配置无效：$id（$validation）');
      final sameId = existingById[id];
      if (sameId != null && _sameProvider(sameId, config)) {
        result.idMap[id] = id;
        result.configs[id] = sameId.toJson();
        result.merged++;
        continue;
      }
      final sameConfig = existingById.values
          .where((p) => _sameProvider(p, config))
          .toList();
      if (sameConfig.isNotEmpty) {
        result.idMap[id] = sameConfig.first.id;
        result.configs[sameConfig.first.id] = sameConfig.first.toJson();
        result.merged++;
        continue;
      }
      final newIdValue = existingIds.contains(id) ? newId() : id;
      final output = ProviderConfig.fromJson({
        ...config.toJson(),
        'id': newIdValue,
      });
      result.idMap[id] = newIdValue;
      result.configs[newIdValue] = output.toJson();
      result.added.add({
        'id': newIdValue,
        'config': jsonEncode(output.toJson()),
      });
      result.addedCount++;
    }
    return result;
  }

  _CategoryMaps _mapCategories(
    List<dynamic> rawCategories,
    _Existing existing,
  ) {
    final result = _CategoryMaps();
    final existingById = <String, String>{};
    final existingByName = <String, String>{};
    for (final row in existing.categories) {
      existingById[row['id'] as String] = row['name'] as String;
      existingByName[row['name'] as String] = row['id'] as String;
    }
    final incomingIds = <String>{};
    for (final raw in rawCategories) {
      final entry = _map(raw, 'categories[]');
      final id = _requiredString(entry['id'], 'categories[].id');
      final name = _requiredString(entry['name'], 'categories[].name');
      if (name.trim().isEmpty) throw BackupException('分类名称不能为空：$id');
      if (!incomingIds.add(id)) throw BackupException('备份包含重复分类 ID：$id');
      if (existingById[id] == name || existingByName[name] != null) {
        result.idMap[id] = existingById[id] == name
            ? id
            : existingByName[name]!;
        result.merged++;
        continue;
      }
      final target = existingById.containsKey(id) ? newId() : id;
      result.idMap[id] = target;
      result.added.add({'id': target, 'name': name});
    }
    return result;
  }

  _PromptMaps _mapPrompts(List<dynamic> rawPrompts, _Existing existing) {
    final result = _PromptMaps();
    final signatures = <String, String>{};
    final ids = <String>{};
    for (final row in existing.prompts) {
      final id = row['id'] as String;
      ids.add(id);
      signatures['${row['title']}\u0000${row['content']}'] = id;
    }
    final incomingIds = <String>{};
    for (final raw in rawPrompts) {
      final entry = _map(raw, 'prompts[]');
      final id = _requiredString(entry['id'], 'prompts[].id');
      final title = _requiredString(entry['title'], 'prompts[].title');
      final content = _requiredString(entry['content'], 'prompts[].content');
      final signature = '$title\u0000$content';
      if (!incomingIds.add(id)) throw BackupException('备份包含重复提示词 ID：$id');
      if (signatures.containsKey(signature)) {
        result.merged++;
        continue;
      }
      final target = ids.contains(id) ? newId() : id;
      result.added.add({
        'id': target,
        'title': title,
        'content': content,
        'updated_at':
            entry['updated_at'] as String? ??
            DateTime.now().toUtc().toIso8601String(),
      });
      ids.add(target);
      signatures[signature] = target;
    }
    return result;
  }

  _TaskMaps _mapTasks(
    List<_IncomingTask> tasks,
    _Existing existing,
    List<Map<String, Object?>> existingRelations,
    List<Map<String, Object?>> existingAttempts,
  ) {
    final result = _TaskMaps();
    final byTask = <String, List<Map<String, Object?>>>{};
    for (final row in existingRelations) {
      byTask.putIfAbsent(row['task_id'] as String, () => []).add(row);
    }
    final attemptsByTask = <String, List<Map<String, Object?>>>{};
    for (final row in existingAttempts) {
      attemptsByTask.putIfAbsent(row['task_id'] as String, () => []).add(row);
    }
    final storedSignatures = <String, String>{};
    for (final row in existingAttempts) {
      final raw = row['metadata'];
      if (raw is! String) continue;
      try {
        final meta = decodeObject(raw);
        final signature = meta['importSignature'];
        if (signature is String && signature.isNotEmpty) {
          storedSignatures[row['task_id'] as String] = signature;
        }
      } catch (_) {
        // Ignore malformed metadata; fall back to the row signature.
      }
    }
    final signatures = <String, String>{};
    for (final row in existing.tasks) {
      final id = row['id'] as String;
      signatures[id] =
          storedSignatures[id] ??
          _ownSignature(
            row,
            (byTask[id] ?? const [])
                .map(
                  (r) => _Relation(
                    taskId: id,
                    assetId: r['asset_id'] as String,
                    role: r['role'] as String,
                    position: r['position'] as int,
                    attempt: r['attempt'] as int,
                  ),
                )
                .toList(),
            (attemptsByTask[id] ?? const [])
                .map(
                  (r) => _Attempt(
                    taskId: id,
                    number: r['number'] as int,
                    startedAt: r['started_at'] as String,
                    endedAt: r['ended_at'] as String?,
                    metadata: r['metadata'] as String,
                    error: r['error'] as String?,
                  ),
                )
                .toList(),
          );
    }
    final ids = <String>{...existing.tasks.map((r) => r['id'] as String)};
    final used = <String>{};
    for (final task in tasks) {
      if (signatures.containsKey(task.id) &&
          signatures[task.id] == task.signature) {
        result.ids[task.id] = task.id;
        result.duplicates.add(task.id);
        used.add(task.id);
        continue;
      }
      var target = task.id;
      if (ids.contains(task.id) || used.contains(task.id)) {
        do {
          target = newId();
        } while (ids.contains(target) || used.contains(target));
        result.remapped.add(task.id);
      }
      result.ids[task.id] = target;
      used.add(target);
      ids.add(target);
    }
    return result;
  }

  _SettingsMap _mapOwnSettings(
    Map<String, dynamic> raw,
    _Existing existing,
    _ProviderMaps providerMaps,
    Map<String, ImageAsset> assets, {
    bool complete = false,
    Map<String, String> taskIds = const {},
  }) {
    final existingKeys = existing.settings
        .map((r) => r['key'] as String)
        .toSet();
    final rows = <Map<String, Object?>>[];
    final seen = <String>{};
    var skipped = 0;

    void add(String key, Object? value) {
      if (!complete && _isSecretKey(key)) return;
      if ((!complete && existingKeys.contains(key)) || !seen.add(key)) {
        skipped++;
        return;
      }
      rows.add({
        'key': key,
        'value': jsonEncode(complete ? value : _sanitize(value)),
      });
    }

    Map<String, dynamic>? draft;
    final rawDraft = raw['draft'];
    if (rawDraft is Map) {
      draft = _remapDraft(
        Map<String, dynamic>.from(rawDraft),
        providerMaps,
        assets,
      );
      if (draft != null && complete && draft['parentTaskId'] is String) {
        draft['parentTaskId'] =
            taskIds[draft['parentTaskId']] ?? draft['parentTaskId'];
      }
    }
    final legacyParams = raw['draft.params'];
    final legacyProvider = raw['draft.activeProviderId'];
    if (!complete && (legacyParams is Map || legacyProvider is String)) {
      draft ??= <String, dynamic>{};
      if (legacyParams is Map) draft['params'] = _sanitize(legacyParams);
      if (legacyProvider is String) {
        draft['providerId'] =
            providerMaps.idMap[legacyProvider] ?? legacyProvider;
      }
    }
    if (draft != null) add('draft', draft);

    for (final entry in raw.entries) {
      final key = entry.key;
      // 备份里的安装索引会伪造已安装/已启用插件，导入时一律忽略。
      if (key == pluginIndexKey || key == StudioStore.draftRevisionKey) {
        skipped++;
        continue;
      }
      if (key == 'draft' && draft != null) continue;
      if (!complete &&
          (key == 'draft.params' || key == 'draft.activeProviderId'))
        continue;
      if (key == 'selection') {
        final value = entry.value;
        final output = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
        final providerId = output['providerId'];
        if (providerId is String)
          output['providerId'] = providerMaps.idMap[providerId] ?? providerId;
        add(key, output);
        continue;
      }
      if (key.startsWith('editor:')) {
        final asset = assets[key.substring('editor:'.length)];
        if (asset == null && !complete) {
          skipped++;
          continue;
        }
        add(asset == null ? key : 'editor:${asset.id}', entry.value);
        continue;
      }
      add(key, entry.value);
    }
    return _SettingsMap(rows: rows, added: rows.length, skipped: skipped);
  }

  Map<String, dynamic>? _remapDraft(
    Map<String, dynamic> draft,
    _ProviderMaps providerMaps,
    Map<String, ImageAsset> assets,
  ) {
    final output = Map<String, dynamic>.from(draft);
    final providerId = output['providerId'];
    if (providerId is String)
      output['providerId'] = providerMaps.idMap[providerId] ?? providerId;
    for (final key in const ['mask', 'markup']) {
      final raw = output[key];
      if (raw == null) continue;
      final mapped = _remapAssetJson(raw, assets);
      if (mapped == null) {
        output.remove(key);
      } else {
        output[key] = mapped;
      }
    }
    final references = output['references'];
    if (references is List) {
      output['references'] = [
        for (final item in references) ?_remapAssetJson(item, assets),
      ];
    }
    for (final key in const ['preprocessors', 'postprocessors']) {
      final raw = output[key];
      if (raw is! List) continue;
      output[key] = [
        for (final item in raw)
          if (item is Map)
            _remapStepJson(Map<String, dynamic>.from(item), (id) => assets[id])
          else
            item,
      ];
    }
    return output;
  }

  Map<String, dynamic>? _remapAssetJson(
    dynamic raw,
    Map<String, ImageAsset> assets,
  ) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String) return null;
    return assets[id]?.toJson();
  }

  /// 预处理后的有效输入快照：provider、引用与父级都换成新 ID，资产缺失时放弃。
  String? _effectiveInputJson(
    _IncomingTask task,
    String taskId,
    Map<String, dynamic> providerJson,
    Map<String, _AssetPlan> plans,
    Map<String, ImageAsset> assets,
    _TaskMaps taskMaps,
  ) {
    final input = task.originalInput;
    if (input == null) return null;
    ImageAsset? map(ImageAsset? asset) {
      if (asset == null) return null;
      return assets[asset.id] ?? plans[asset.id]?.asset;
    }

    final references = <ImageAsset>[];
    for (final asset in input.references) {
      final mapped = map(asset);
      if (mapped == null) return null;
      references.add(mapped);
    }
    final mask = map(input.mask);
    final markup = map(input.markup);
    if (input.mask != null && mask == null) return null;
    if (input.markup != null && markup == null) return null;
    final parentAssetId = input.parentAssetId;
    final parentAsset = parentAssetId == null
        ? null
        : (assets[parentAssetId] ?? plans[parentAssetId]?.asset);
    final rebuilt = GenerationInput(
      taskId: taskId,
      provider: ProviderConfig.fromJson(providerJson),
      prompt: input.prompt,
      params: input.params,
      references: references,
      mask: mask,
      markup: markup,
      parentTaskId: input.parentTaskId == null
          ? null
          : (taskMaps.ids[input.parentTaskId] ?? input.parentTaskId),
      parentAssetId: parentAsset?.id ?? parentAssetId,
      postprocessors: [
        for (final step in input.postprocessors)
          _remapStep(step, plans, assets),
      ],
    );
    return jsonEncode(rebuilt.toJson());
  }

  /// 处理步骤参数里可能内嵌资产引用，导入时按新 ID 重映射。
  Map<String, dynamic> _remapStepJson(
    Map<String, dynamic> step,
    ImageAsset? Function(String id) lookup,
  ) {
    final params = step['params'];
    return {
      ...step,
      if (params != null) 'params': _remapParamValue(params, lookup),
    };
  }

  ProcessingStep _remapStep(
    ProcessingStep step,
    Map<String, _AssetPlan> plans,
    Map<String, ImageAsset> assets,
  ) => ProcessingStep.fromJson(
    _remapStepJson(step.toJson(), (id) => assets[id] ?? plans[id]?.asset),
  );

  Object? _remapParamValue(
    Object? value,
    ImageAsset? Function(String id) lookup,
  ) {
    if (value is Map) {
      final id = value['id'];
      final mapped = id is String ? lookup(id) : null;
      if (mapped != null) return mapped.toJson();
      return {
        for (final entry in value.entries)
          entry.key.toString(): _remapParamValue(entry.value, lookup),
      };
    }
    if (value is List) {
      return [for (final item in value) _remapParamValue(item, lookup)];
    }
    return value;
  }

  Future<void> _stage(_PreparedImport prepared) async {
    final base = Directory('${store.root.path}/$_stagingFolder');
    final session = Directory('${base.path}/${prepared.sessionId}');
    final journal = File('${base.path}/${prepared.sessionId}.json');
    try {
      await session.create(recursive: true);
      final files = [
        for (var i = 0; i < prepared.stagedAssets.length; i++)
          {
            'hash': prepared.stagedAssets[i].hash,
            'staged': 'staged/$i',
            'final': prepared.stagedAssets[i].finalPath,
          },
      ];
      await journal.writeAsString(
        jsonEncode({
          'sessionId': prepared.sessionId,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'files': files,
        }),
        flush: true,
      );
      final stagedDir = Directory('${session.path}/staged');
      await stagedDir.create(recursive: true);
      for (var i = 0; i < prepared.stagedAssets.length; i++) {
        final file = File('${stagedDir.path}/$i');
        await prepared.stagedAssets[i].file.disk!.rename(file.path);
      }
    } catch (error) {
      await _cleanupBestEffort(prepared);
      throw BackupException('备份文件暂存失败：$error');
    }
  }

  Future<BackupImportResult> _commit(_PreparedImport prepared) =>
      _operation(() => _commitUnlocked(prepared));

  Future<BackupImportResult> _commitUnlocked(_PreparedImport prepared) async {
    final moved = <File>[];
    var committed = false;
    try {
      await _assertIdle(store.db);
      for (var i = 0; i < prepared.stagedAssets.length; i++) {
        final asset = prepared.stagedAssets[i];
        if (asset.file.memory != null) continue;
        final stagedFile = File(
          '${store.root.path}/$_stagingFolder/${prepared.sessionId}/staged/$i',
        );
        final finalFile = File('${store.root.path}/${asset.finalPath}');
        if (await finalFile.exists()) {
          final existingHash = await _sha256File(finalFile);
          if (existingHash != asset.hash) {
            throw BackupException('目标图片文件已存在且内容不一致，未覆盖：${asset.finalPath}');
          }
          continue;
        }
        await Directory(finalFile.parent.path).create(recursive: true);
        await stagedFile.rename(finalFile.path);
        moved.add(finalFile);
      }

      await store.db.transaction((tx) async {
        await _assertIdle(tx);
        for (final row in prepared.providers) {
          await tx.insert('providers', row);
        }
        for (final row in prepared.assets) {
          await tx.insert('assets', row);
        }
        for (final staged in prepared.stagedAssets) {
          final bytes = staged.file.memory;
          if (bytes != null) await store.writeRestoredAssetBytes(tx, staged.asset, bytes);
        }
        for (final row in prepared.categories) {
          await tx.insert('categories', row);
        }
        for (final row in prepared.prompts) {
          await tx.insert('prompts', row);
        }
        for (final row in prepared.settings) {
          await tx.insert(
            'settings',
            row,
            conflictAlgorithm: prepared.replaceSettings
                ? ConflictAlgorithm.replace
                : ConflictAlgorithm.ignore,
          );
        }
        if (prepared.replaceSettings && prepared.settings.any((row) => row['key'] == 'draft')) {
          await tx.insert('settings', {
            'key': StudioStore.draftRevisionKey,
            'value': jsonEncode({'id': newId()}),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final row in prepared.tasks) {
          await tx.insert('tasks', row);
        }
        for (final row in prepared.taskAssets) {
          await tx.insert('task_assets', row);
        }
        for (final row in prepared.attempts) {
          await tx.insert('attempts', row);
        }
        for (final row in prepared.pipeline) {
          await tx.insert(
            'pipeline_state',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        for (final row in prepared.errors) {
          await tx.insert('errors', row);
        }
      });
      committed = true;

      final keyWarnings = <String>[];
      for (final entry in prepared.credentials.entries) {
        try {
          await store.credentials.write(key: entry.key, value: entry.value);
        } catch (_) {
          keyWarnings.add('有 1 项密钥未能写入安全存储，请在供应商设置中手动补填；保留备份文件以便重试。');
        }
      }
      await _cleanupBestEffort(prepared);
      try {
        store.refresh();
      } catch (_) {
        // The data is already committed; a listener failure must not trigger rollback.
      }
      final allWarnings = [...prepared.warnings, ...keyWarnings];
      return BackupImportResult(
        BackupImportPreview(
          format: prepared.preview.format,
          tasks: prepared.preview.tasks,
          duplicateTasks: prepared.preview.duplicateTasks,
          remappedTasks: prepared.preview.remappedTasks,
          assets: prepared.preview.assets,
          duplicateAssets: prepared.preview.duplicateAssets,
          providersAdded: prepared.preview.providersAdded,
          providersMerged: prepared.preview.providersMerged,
          categoriesAdded: prepared.preview.categoriesAdded,
          categoriesMerged: prepared.preview.categoriesMerged,
          promptsAdded: prepared.preview.promptsAdded,
          promptsMerged: prepared.preview.promptsMerged,
          settingsAdded: prepared.preview.settingsAdded,
          settingsSkipped: prepared.preview.settingsSkipped,
          warnings: allWarnings,
        ),
      );
    } catch (error) {
      if (!committed) {
        for (final file in moved) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {
            // Best effort only; the journal recovery can retry later.
          }
        }
      }
      await _cleanupBestEffort(prepared);
      if (committed) {
        throw BackupException('导入已写入，但收尾未完成：$error');
      }
      if (error is BackupException) rethrow;
      throw BackupException('导入失败，已回滚本批新增并保留现有数据：$error');
    } finally {
      _activeSessions.remove(prepared.sessionId);
    }
  }

  Future<void> _discard(_PreparedImport prepared) => _operation(() async {
    _activeSessions.remove(prepared.sessionId);
    await _cleanupBestEffort(prepared);
  });

  Future<void> _cleanup(_PreparedImport prepared) async {
    if (kIsWeb) return;
    final base = Directory('${store.root.path}/$_stagingFolder');
    final session = Directory('${base.path}/${prepared.sessionId}');
    final journal = File('${base.path}/${prepared.sessionId}.json');
    if (await session.exists()) await _deleteTree(session);
    if (await journal.exists()) await journal.delete();
  }

  Future<void> _cleanupBestEffort(_PreparedImport prepared) async {
    try {
      await _cleanup(prepared);
    } catch (_) {
      // Staging cleanup must not turn a successful commit into a failure.
    }
  }

  Future<void> _deleteTree(Directory directory) async {
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is Directory) {
        await _deleteTree(entry);
      } else {
        await entry.delete();
      }
    }
    await directory.delete();
  }

  Future<void> _assertIdle(DatabaseExecutor db) async {
    final rows = await db.query(
      'tasks',
      columns: ['id'],
      where: 'status IN (?, ?)',
      whereArgs: [TaskStatus.running.name, TaskStatus.queued.name],
      limit: 1,
    );
    if (rows.isNotEmpty) throw const BackupException('有任务正在执行或排队，完成后再导入');
  }

  ImageAsset _assetFor(
    String id,
    Map<String, _AssetPlan> plans,
    Map<String, ImageAsset> actual,
  ) {
    final plan = plans[id];
    if (plan == null) {
      final existing = actual[id];
      if (existing != null) return existing;
      throw BackupException('导入包缺少被引用的图片：$id');
    }
    return plan.asset;
  }

  void _requireAsset(
    String id,
    Map<String, _AssetPlan> plans,
    Map<String, ImageAsset> existing,
  ) {
    if (!plans.containsKey(id) && !existing.containsKey(id)) {
      throw BackupException('导入包缺少被引用的图片：$id');
    }
  }
}

class _Existing {
  const _Existing({
    required this.providers,
    required this.categories,
    required this.prompts,
    required this.tasks,
    required this.assets,
    required this.taskAssets,
    required this.attempts,
    required this.settings,
  });

  final List<Map<String, Object?>> providers;
  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> prompts;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> assets;
  final List<Map<String, Object?>> taskAssets;
  final List<Map<String, Object?>> attempts;
  final List<Map<String, Object?>> settings;
}

class _AssetPlan {
  const _AssetPlan({
    required this.oldId,
    required this.asset,
    required this.file,
  });

  final String oldId;
  final ImageAsset asset;
  final _ImportEntry? file;
}

class _Relation {
  const _Relation({
    required this.taskId,
    required this.assetId,
    required this.role,
    required this.position,
    required this.attempt,
  });

  final String taskId;
  final String assetId;
  final String role;
  final int position;
  final int attempt;
}

/// 任务的处理断点：与 pipeline_state 表一一对应。
class _PipelineRow {
  const _PipelineRow({
    required this.taskId,
    required this.stage,
    required this.position,
    required this.attempt,
    required this.step,
    required this.sourceAssetId,
    required this.message,
    required this.expected,
    required this.updatedAt,
  });

  final String taskId;
  final String stage;
  final int position;
  final int attempt;
  final int step;
  final String? sourceAssetId;
  final String? message;
  final int? expected;
  final String updatedAt;
}

class _Attempt {
  const _Attempt({
    required this.taskId,
    required this.number,
    required this.startedAt,
    required this.endedAt,
    required this.metadata,
    required this.error,
  });

  final String taskId;
  final int number;
  final String startedAt;
  final String? endedAt;
  final String metadata;
  final String? error;
}

class _IncomingTask {
  const _IncomingTask({
    required this.id,
    required this.prompt,
    required this.params,
    required this.referenceIds,
    required this.maskId,
    required this.markupId,
    required this.parentTaskId,
    required this.parentAssetId,
    required this.providerId,
    required this.providerSnapshot,
    required this.status,
    required this.createdAt,
    required this.favorite,
    required this.categoryId,
    required this.deletedAt,
    required this.error,
    required this.attempt,
    required this.relations,
    required this.attempts,
    required this.signature,
    required this.source,
    required this.upstreamVersion,
    required this.compatMeta,
    this.preprocessors = const [],
    this.postprocessors = const [],
    this.originalInput,
    this.pipeline,
  });

  final String id;
  final String prompt;
  final GenerationParams params;
  final List<String> referenceIds;
  final String? maskId;
  final String? markupId;
  final String? parentTaskId;
  final String? parentAssetId;
  final String? providerId;
  final Map<String, dynamic> providerSnapshot;
  final String status;
  final String createdAt;
  final int favorite;
  final String? categoryId;
  final String? deletedAt;
  final String? error;
  final int attempt;
  final List<_Relation> relations;
  final List<_Attempt> attempts;
  final String signature;
  final String source;
  final int? upstreamVersion;
  final Map<String, dynamic>? compatMeta;

  /// 生成前/后的本地处理步骤，旧备份为空。
  final List<ProcessingStep> preprocessors;
  final List<ProcessingStep> postprocessors;

  /// 预处理后的有效输入快照，旧备份为空。
  final GenerationInput? originalInput;

  /// 处理断点，旧备份为空。
  final _PipelineRow? pipeline;
}

class _ProviderMaps {
  final List<Map<String, Object?>> added = [];
  final Map<String, String> idMap = {};
  final Map<String, Map<String, dynamic>> configs = {};
  int merged = 0;
  int addedCount = 0;
}

class _CategoryMaps {
  final List<Map<String, Object?>> added = [];
  final Map<String, String> idMap = {};
  int merged = 0;
}

class _PromptMaps {
  final List<Map<String, Object?>> added = [];
  int merged = 0;
}

class _TaskMaps {
  final Map<String, String> ids = {};
  final Set<String> duplicates = {};
  final Set<String> remapped = {};
}

class _SettingsMap {
  const _SettingsMap({
    required this.rows,
    required this.added,
    required this.skipped,
  });

  final List<Map<String, Object?>> rows;
  final int added;
  final int skipped;
}

class _ImportEntry {
  const _ImportEntry.disk(this.disk) : memory = null;
  const _ImportEntry.memory(this.memory) : disk = null;

  final File? disk;
  final Uint8List? memory;

  Future<int> length() async => memory?.length ?? await disk!.length();
  Future<Uint8List> readAsBytes() async => memory ?? await disk!.readAsBytes();
  Future<String> hash() => memory == null ? _sha256File(disk!) : _sha256(memory!);
}
class _StagedAsset {
  const _StagedAsset({required this.asset, required this.file});

  final ImageAsset asset;
  final _ImportEntry file;
  String get hash => asset.hash;
  String get finalPath => asset.path;
}

class _PreparedImport {
  _PreparedImport({
    required this.preview,
    required this.sessionId,
    required this.providers,
    required this.assets,
    required this.categories,
    required this.prompts,
    required this.settings,
    required this.tasks,
    required this.taskAssets,
    required this.attempts,
    required this.stagedAssets,
    required this.credentials,
    required this.errors,
    required this.pipeline,
    required this.replaceSettings,
    required this.warnings,
  });

  final BackupImportPreview preview;
  final String sessionId;
  final List<Map<String, Object?>> providers;
  final List<Map<String, Object?>> assets;
  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> prompts;
  final List<Map<String, Object?>> settings;
  final List<Map<String, Object?>> tasks;
  final List<Map<String, Object?>> taskAssets;
  final List<Map<String, Object?>> attempts;
  final List<Map<String, Object?>> pipeline;
  final List<_StagedAsset> stagedAssets;
  final Map<String, String> credentials;
  final List<Map<String, Object?>> errors;
  final bool replaceSettings;
  final List<String> warnings;
}

Future<String> _sha256(Uint8List bytes) => compute(_hashBytes, bytes);

Future<String> _sha256File(File file) async {
  return (await sha256.bind(file.openRead()).first).toString();
}

String _hashBytes(Uint8List bytes) => sha256.convert(bytes).toString();

void _collectAssetReferences(Object? value, Set<String> ids) {
  if (value is Map) {
    if (value['id'] is String &&
        value['hash'] is String &&
        value['path'] is String) {
      ids.add(value['id'] as String);
    } else {
      for (final item in value.values) {
        _collectAssetReferences(item, ids);
      }
    }
  } else if (value is List) {
    for (final item in value) {
      _collectAssetReferences(item, ids);
    }
  }
}

Map<String, dynamic> _map(dynamic value, String path) {
  if (value is Map) return Map<String, dynamic>.from(value);
  throw BackupException('备份字段无效：$path');
}

List<dynamic> _list(dynamic value, String path) {
  if (value is List) return value;
  throw BackupException('备份字段无效：$path');
}

String _requiredString(dynamic value, String path) {
  if (value is String && value.isNotEmpty) return value;
  throw BackupException('备份字段无效：$path');
}

String? _optionalString(dynamic value, String path) {
  if (value == null) return null;
  if (value is String) return value;
  throw BackupException('备份字段无效：$path');
}

int _requiredInt(dynamic value, String path) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw BackupException('备份字段无效：$path');
}

int? _optionalInt(dynamic value, String path) {
  if (value == null) return null;
  return _requiredInt(value, path);
}

DateTime _parseDate(String value, String path) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw BackupException('备份字段无效：$path');
  return parsed;
}

String _upstreamTime(dynamic value, String path) {
  if (value is int && value > 0)
    return DateTime.fromMillisecondsSinceEpoch(
      value,
      isUtc: true,
    ).toIso8601String();
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt(),
      isUtc: true,
    ).toIso8601String();
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toUtc().toIso8601String();
  }
  throw BackupException('备份字段无效：$path');
}

List<String> _stringList(dynamic value, String path) {
  if (value == null) return const [];
  if (value is! List) throw BackupException('备份字段无效：$path');
  return [for (final item in value) _requiredString(item, path)];
}

String _upstreamStatus(
  String value,
  Map<String, dynamic> row,
  List<String> warnings,
) {
  switch (value) {
    case 'running':
      warnings.add('上游备份中有执行中的任务，已恢复为“已中断”并保留完成的图片。');
      return 'interrupted';
    case 'partial_error':
      return 'partialError';
    case 'done':
    case 'error':
      return value;
    default:
      throw BackupException('上游任务状态不受支持：$value');
  }
}

void _validateEditSelection(dynamic value) {
  if (value == null) return;
  if (value is! Map) throw const BackupException('备份字段无效：editSelection');
  for (final key in const ['x', 'y', 'width', 'height']) {
    final number = value[key];
    if (number is! num || number < 0 || number > 1) {
      throw const BackupException('备份字段无效：editSelection');
    }
  }
}

GenerationParams _paramsFromUpstream(Map<String, dynamic> params) {
  final unknown = params.keys.where(
    (key) => !_upstreamParams.contains(key) && key != 'quality',
  );
  if (unknown.isNotEmpty) {
    // Unknown params are tolerated and dropped; upstream added fields over time.
  }
  final size = params['size'] as String? ?? 'auto';
  if (size != 'auto' && !RegExp(r'^\d+x\d+$').hasMatch(size)) {
    throw BackupException('上游任务尺寸无效：$size');
  }
  final count = params['n'] == null ? 1 : _requiredInt(params['n'], 'params.n');
  if (count < 1 || count > 10) throw BackupException('上游任务数量无效：$count');
  final format = params['output_format'] as String? ?? 'png';
  if (!const {'png', 'jpeg', 'webp', 'gif', 'svg'}.contains(format)) {
    throw BackupException('上游任务格式无效：$format');
  }
  final compression = params['output_compression'] == null
      ? 100
      : _requiredInt(params['output_compression'], 'params.output_compression');
  if (compression < 0 || compression > 100)
    throw BackupException('上游任务压缩质量无效：$compression');
  final frames = params['frame_count'] == null
      ? 9
      : _requiredInt(params['frame_count'], 'params.frame_count');
  final duration = params['frame_duration_ms'] == null
      ? 200
      : _requiredInt(params['frame_duration_ms'], 'params.frame_duration_ms');
  if (frames < 1 || duration < 1) throw const BackupException('上游任务动图参数无效');
  return GenerationParams(
    size: size,
    quality: params['quality'] as String? ?? 'auto',
    count: count,
    format: format,
    compression: compression,
    background: params['background'] as String? ?? 'auto',
    moderation: params['moderation'] as String? ?? 'auto',
    inputFidelity: params['input_fidelity'] as String? ?? 'high',
    complexity: params['complexity'] as String? ?? '',
    gifFrames: frames,
    gifDuration: duration,
  );
}

ProviderConfig _providerFromUpstream(Map<String, dynamic> entry) {
  final id = _requiredString(entry['id'], 'providers[].id');
  final baseUrl = entry['baseUrl'] as String? ?? 'https://api.openai.com/v1';
  final uri = Uri.tryParse(baseUrl);
  if (uri == null ||
      !uri.hasScheme ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw BackupException('上游供应商地址无效：$id');
  }
  final protocol = entry['apiProtocol'] == 'responses'
      ? ApiProtocol.responses
      : ApiProtocol.images;
  final transport = _transport(entry['responsesTransport'] as String?);
  final timeout = entry['timeout'] == null
      ? 900
      : _requiredInt(entry['timeout'], 'providers[].timeout');
  final partial = entry['partialImages'] == null
      ? 1
      : _requiredInt(entry['partialImages'], 'providers[].partialImages');
  final config = ProviderConfig(
    id: id,
    name: entry['name'] as String? ?? id,
    baseUrl: baseUrl,
    enabled: entry['enabled'] as bool? ?? true,
    allowHttp: uri.scheme == 'http',
    protocol: protocol,
    imageModel: entry['model'] as String? ?? 'gpt-image-1',
    responseModel: entry['responsesImageModel'] as String? ?? 'gpt-4.1',
    toolModel:
        entry['toolModel'] as String? ??
        (entry['model'] as String? ?? 'gpt-image-1'),
    transport: transport,
    fileInput: entry['responsesImageInputMode'] == 'file',
    promptCompatibility: entry['responsesPromptRevisionMode'] == 'compat',
    timeoutSeconds: timeout,
    partialImages: partial,
    safetyIdentifier: entry['safetyIdentifier'] as String? ?? '',
  );
  final validation = config.validate();
  if (validation != null) throw BackupException('上游供应商配置无效：$id（$validation）');
  return config;
}

Future<void> _validateImage(Uint8List bytes, String mime, String label) async {
  try {
    await validateImage(bytes, mime);
  } catch (_) {
    throw BackupException('图片内容与声明的格式不符：$label');
  }
}

class _ZipLimitException implements Exception {
  const _ZipLimitException(this.message);

  final String message;
}

class _BoundedZipOutput extends OutputMemoryStream {
  _BoundedZipOutput({required this.maxBytes, required this.fileName});

  final int maxBytes;
  final String fileName;

  void _check(int count) {
    if (count < 0 || length + count > maxBytes) {
      throw _ZipLimitException('ZIP 中单个文件超过 64 MB：$fileName');
    }
  }

  @override
  void reserve(int total) {
    if (total > maxBytes) {
      throw _ZipLimitException('ZIP 中单个文件超过 64 MB：$fileName');
    }
    super.reserve(total);
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}

TransportMode _transport(String? value) => switch (value) {
  'stream' => TransportMode.stream,
  'json' => TransportMode.json,
  _ => TransportMode.auto,
};

ProviderConfig _fallbackProvider(Map<String, dynamic> settings) {
  final rawBase = settings['baseUrl'] as String?;
  final uri = rawBase == null ? null : Uri.tryParse(rawBase);
  final baseUrl = uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
      ? rawBase!
      : 'https://api.openai.com/v1';
  final parsed = Uri.parse(baseUrl);
  final timeout = settings['timeout'] is int ? settings['timeout'] as int : 900;
  final partial = settings['partialImages'] is int
      ? settings['partialImages'] as int
      : 1;
  final protocol = settings['apiProtocol'] == 'responses'
      ? ApiProtocol.responses
      : ApiProtocol.images;
  final transport = _transport(settings['responsesTransport'] as String?);
  return ProviderConfig(
    id: 'upstream-default',
    name: '上游默认配置',
    baseUrl: baseUrl,
    allowHttp: parsed.scheme == 'http',
    protocol: protocol,
    imageModel: settings['model'] as String? ?? 'gpt-image-1',
    responseModel: settings['responsesImageModel'] as String? ?? 'gpt-4.1',
    toolModel: settings['model'] as String? ?? 'gpt-image-1',
    transport: transport,
    timeoutSeconds: timeout < 1 ? 1 : (timeout > 3600 ? 3600 : timeout),
    partialImages: partial < 0 ? 0 : (partial > 3 ? 3 : partial),
    safetyIdentifier: settings['safetyIdentifier'] as String? ?? '',
  );
}

String _upstreamMime(Map<String, dynamic> meta, String id) {
  final declared = meta['mimeType'] as String?;
  if (declared != null && _extensionByMime.containsKey(declared))
    return declared;
  final path = meta['path'] as String? ?? '';
  final extension = path.contains('.')
      ? path.split('.').last.toLowerCase()
      : '';
  final mime = _mimeByExtension[extension];
  if (mime == null) throw BackupException('无法确定图片格式：$id');
  return mime;
}

String _metadataJson(Map<String, dynamic> metadata) {
  var encoded = jsonEncode(metadata);
  if (encoded.length > _maxMetadataChars) {
    encoded = jsonEncode({
      'source': metadata['source'],
      'version': metadata['version'],
      if (metadata['taskKind'] != null) 'taskKind': metadata['taskKind'],
      'note': '上游元数据过大，已省略',
    });
  }
  return encoded;
}

Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalJson(value[key])};
  }
  if (value is List) return [for (final item in value) _canonicalJson(item)];
  return value;
}

String _ownSignature(
  Map<String, Object?> row,
  List<_Relation> relations,
  List<_Attempt> attempts,
) {
  final sortedRelations = [...relations]
    ..sort(
      (a, b) => '${a.assetId}/${a.role}/${a.attempt}/${a.position}'.compareTo(
        '${b.assetId}/${b.role}/${b.attempt}/${b.position}',
      ),
    );
  final sortedAttempts = [...attempts]
    ..sort((a, b) => a.number.compareTo(b.number));
  final input = row['input'] is String
      ? decodeObject(row['input'] as String)
      : row['input'];
  return jsonEncode({
    'id': row['id'],
    'input': _canonicalJson(input),
    'status': row['status'],
    'created_at': row['created_at'],
    'favorite': row['favorite'],
    'category_id': row['category_id'],
    'deleted_at': row['deleted_at'],
    'error': row['error'],
    'attempt': row['attempt'],
    'relations': [
      for (final r in sortedRelations)
        [r.assetId, r.role, r.position, r.attempt],
    ],
    'attempts': [
      for (final a in sortedAttempts)
        [a.number, a.startedAt, a.endedAt, a.metadata, a.error],
    ],
  });
}

String _upstreamSignature(
  Map<String, dynamic> row,
  String status,
  String createdAt,
  GenerationParams params,
  List<String> inputs,
  List<String> outputs,
) {
  return jsonEncode({
    'id': row['id'],
    'prompt': row['prompt'] ?? '',
    'params': params.toJson(),
    'status': status,
    'createdAt': createdAt,
    'providerId': row['providerId'],
    'categoryId': row['categoryId'],
    'inputs': inputs,
    'outputs': outputs,
    'mask': row['editMaskImageId'],
    'markup': row['editMarkupImageId'],
    'source': row['editSourceImageId'],
    'parent': row['parentTaskId'],
  });
}

bool _sameProvider(ProviderConfig a, ProviderConfig b) {
  final left = a.toJson()..remove('id');
  final right = b.toJson()..remove('id');
  return jsonEncode(left) == jsonEncode(right);
}

bool _isSecretKey(String key) => _secretKeys.contains(key.toLowerCase());

dynamic _sanitize(dynamic value) {
  if (value is Map) {
    final output = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (_isSecretKey(key)) continue;
      output[key] = _sanitize(entry.value);
    }
    return output;
  }
  if (value is List) return value.map(_sanitize).toList();
  return value;
}

List<Map<String, Object?>> _redactExportRows(List<Map<String, Object?>> rows, List<String> fields) => [
  for (final row in rows)
    {
      ...row,
      for (final field in fields)
        if (row[field] case final String raw when raw.isNotEmpty)
          field: jsonEncode(_sanitize(jsonDecode(raw))),
    },
];
