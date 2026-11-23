import 'dart:convert';
import 'dart:io' show Directory, File;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/utils/utils.dart' show firstIntValue;

import '../models/models.dart';

import 'image_validation.dart';
import 'studio_store_native.dart'
    if (dart.library.js_interop) 'studio_store_web.dart' as platform;

class StudioStore extends ChangeNotifier {
  StudioStore(Database db, Directory root, {FlutterSecureStorage? credentials})
    : this._(db, root, credentials: credentials);
  StudioStore._(this.db, this._root, {FlutterSecureStorage? credentials})
    : credentials = credentials ?? const FlutterSecureStorage(
        // ad hoc 签名的 macOS release 仍使用钥匙串保存凭据。
        mOptions: MacOsOptions(usesDataProtectionKeychain: !kReleaseMode),
      );
  final Database db;
  final Directory? _root;
  Directory get root => _root ?? (throw UnsupportedError('Web 没有本地存储目录'));
  final FlutterSecureStorage credentials;

  static Future<StudioStore> open({
    DatabaseFactory? factory,
    Directory? directory,
  }) async {
    final root = await platform.prepareStudioRoot(directory);
    final db = await (factory ?? platform.studioDatabaseFactory()).openDatabase(
      root == null ? 'studio.db' : '${root.path}/studio.db',
      options: OpenDatabaseOptions(
        version: 2,
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute('ALTER TABLE task_assets RENAME TO task_assets_v1');
            await db.execute(_taskAssetsSchema);
            await db.execute('INSERT INTO task_assets SELECT * FROM task_assets_v1');
            await db.execute('DROP TABLE task_assets_v1');
          }
        },
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE providers(id TEXT PRIMARY KEY, config TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE assets(id TEXT PRIMARY KEY, hash TEXT NOT NULL UNIQUE, data TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE tasks(id TEXT PRIMARY KEY, input TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL, favorite INTEGER NOT NULL DEFAULT 0, category_id TEXT, deleted_at TEXT, error TEXT, attempt INTEGER NOT NULL DEFAULT 0, original_input TEXT)',
          );
          await db.execute(_taskAssetsSchema);
          await db.execute(
            'CREATE TABLE attempts(task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, number INTEGER NOT NULL, started_at TEXT NOT NULL, ended_at TEXT, metadata TEXT NOT NULL DEFAULT \'{}\', error TEXT, PRIMARY KEY(task_id,number))',
          );
          await db.execute(
            'CREATE TABLE categories(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE prompts(id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, updated_at TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE errors(id TEXT PRIMARY KEY, task_id TEXT, message TEXT NOT NULL, created_at TEXT NOT NULL)',
          );
          if (kIsWeb) {
            await db.execute(_pipelineStateSchema);
            await db.execute(
              'CREATE TABLE asset_bytes(asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE, path TEXT NOT NULL, bytes BLOB NOT NULL, created_at INTEGER NOT NULL)',
            );
          }
        },
      ),
    );
    if (!kIsWeb) {
      // 保留原生旧数据库的追加表与补列逻辑。
      await db.execute(_pipelineStateSchema);
      try {
        await db.execute('ALTER TABLE pipeline_state ADD COLUMN expected INTEGER');
      } on Object catch (_) {}
      try {
        await db.execute('ALTER TABLE tasks ADD COLUMN original_input TEXT');
      } on Object catch (_) {}
    }
    return StudioStore._(db, root);
  }

  Future<List<ProviderConfig>> providers() async =>
      (await db.query('providers', orderBy: 'rowid'))
          .map(
            (r) => ProviderConfig.fromJson(decodeObject(r['config'] as String)),
          )
          .toList();
  static const _boundKeyPrefix = 'image-gen-key-v1:';
  static String bindProviderKey(String baseUrl, String key) =>
      '$_boundKeyPrefix${jsonEncode([Uri.parse(baseUrl).origin, key])}';

  static String? providerKeyForOrigin(String value, String baseUrl) {
    if (!value.startsWith(_boundKeyPrefix)) return value;
    final binding = jsonDecode(value.substring(_boundKeyPrefix.length)) as List;
    return binding[0] == Uri.parse(baseUrl).origin ? binding[1] as String : null;
  }

  Future<String?> _providerAddress(String id) async {
    final rows = await db.query('providers', columns: ['config'], where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : decodeObject(rows.single['config'] as String)['baseUrl'] as String?;
  }

  Future<String?> apiKey(String id, {String? baseUrl}) async {
    final current = await _providerAddress(id);
    if (current == null || (baseUrl != null && Uri.parse(current).origin != Uri.parse(baseUrl).origin)) return null;
    final value = await credentials.read(key: 'provider:$id');
    return value == null ? null : providerKeyForOrigin(value, current);
  }

  Future<void> saveProvider(ProviderConfig provider, {String? key}) async {
    final error = provider.validate();
    if (error != null) throw FormatException(error);
    final previous = key == null ? await _providerAddress(provider.id) : null;
    if (previous != null && Uri.parse(previous).origin != Uri.parse(provider.baseUrl).origin &&
        await credentials.read(key: 'provider:${provider.id}') != null) {
      throw StateError('API 地址来源已变更，请重新填写密钥');
    }
    // 密钥先写入安全存储；新旧地址交错时按来源拒绝读取。
    if (key != null) await credentials.write(
      key: 'provider:${provider.id}',
      value: bindProviderKey(provider.baseUrl, key.trim()),
    );
    await db.insert('providers', {
      'id': provider.id,
      'config': jsonEncode(provider.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deleteProvider(String id) async {
    await credentials.delete(key: 'provider:$id');
    await db.delete('providers', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  File fileFor(ImageAsset asset) {
    _validateAssetPath(asset);
    return platform.studioFile(root, asset.path);
  }

  Future<Uint8List> readAsset(ImageAsset asset) async {
    if (!kIsWeb) return fileFor(asset).readAsBytes();
    final bytes = await _readStoredAssetColumn(asset, 'bytes') as Uint8List;
    if (bytes.isEmpty || bytes.length > _maxAssetBytes) {
      throw const FormatException('图片大小无效（最多 64 MB）');
    }
    return bytes;
  }

  Future<int> assetLength(ImageAsset asset) async {
    if (!kIsWeb) return fileFor(asset).length();
    return await _readStoredAssetColumn(asset, 'length(bytes)') as int;
  }

  Future<Object?> _readStoredAssetColumn(ImageAsset asset, String column) async {
    _validateAssetPath(asset);
    final rows = await db.query(
      'asset_bytes',
      columns: [column],
      where: 'asset_id = ? AND path = ?',
      whereArgs: [asset.id, asset.path],
    );
    if (rows.isEmpty) throw StateError('图片不存在：${asset.path}');
    return rows.single.values.single;
  }

  /// 调用方须先在同一事务中写入对应的 assets 元数据。
  Future<void> writeRestoredAssetBytes(
    Transaction tx,
    ImageAsset asset,
    Uint8List bytes,
  ) async {
    if (!kIsWeb) throw UnsupportedError('原生恢复使用图片文件');
    _validateAssetPath(asset);
    if (bytes.isEmpty || bytes.length > _maxAssetBytes ||
        bytes.length != asset.bytes || _hash(bytes) != asset.hash) {
      throw const FormatException('恢复图片的大小或内容与记录不一致');
    }
    await _writeStoredAssetBytes(tx, asset, bytes);
  }

  Future<void> _writeStoredAssetBytes(
    Transaction tx,
    ImageAsset asset,
    Uint8List bytes,
  ) async {
    await tx.insert('asset_bytes', {
      'asset_id': asset.id,
      'path': asset.path,
      'bytes': bytes,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<ImageAsset> saveAsset(
    Uint8List bytes,
    String mime, {
    String? remoteUrl,
  }) async {
    const extensions = {
      'image/png': 'png',
      'image/jpeg': 'jpeg',
      'image/webp': 'webp',
      'image/gif': 'gif',
      'image/svg+xml': 'svg',
    };
    final extension = extensions[mime];
    if (extension == null || bytes.isEmpty || bytes.length > _maxAssetBytes)
      throw const FormatException('图片格式或大小无效（最多 64 MB）');
    final size = await validateImage(bytes, mime);
    final hash = await compute(_hash, bytes);
    final asset = ImageAsset(
      id: hash,
      path: 'assets/$hash.$extension',
      mime: mime,
      hash: hash,
      bytes: bytes.length,
      width: size.width,
      height: size.height,
      remoteUrl: remoteUrl,
    );
    final metadata = {
      'id': asset.id,
      'hash': hash,
      'data': jsonEncode(asset.toJson()),
    };

    Future<ImageAsset?> existing(DatabaseExecutor executor) async {
      final rows = await executor.query('assets', where: 'hash = ?', whereArgs: [hash]);
      return rows.isEmpty
          ? null
          : ImageAsset.fromJson(decodeObject(rows.single['data'] as String));
    }

    if (kIsWeb) {
      return db.transaction((tx) async {
        final saved = await existing(tx);
        if (saved != null) return saved;
        await tx.insert('assets', metadata);
        await _writeStoredAssetBytes(tx, asset, bytes);
        return asset;
      });
    }
    final saved = await existing(db);
    if (saved != null) return saved;
    await platform.writeStudioFile(root, asset.path, bytes);
    await db.insert('assets', metadata, conflictAlgorithm: ConflictAlgorithm.ignore);
    return asset;
  }

  Future<void> importAsset(ImageAsset asset, ProviderConfig provider) async {
    final input = GenerationInput(
      taskId: newId(),
      provider: provider,
      prompt: '导入的图片',
      params: const GenerationParams(),
    );
    await db.transaction((tx) async {
      await tx.insert('tasks', {
        'id': input.taskId,
        'input': jsonEncode(input.toJson()),
        'status': 'done',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await tx.insert('task_assets', {
        'task_id': input.taskId,
        'asset_id': asset.id,
        'role': 'output',
        'position': 0,
        'attempt': 0,
      });
    });
    notifyListeners();
  }

  Future<void> enqueue(GenerationInput input) async {
    await db.transaction((tx) async {
      await tx.insert('tasks', {
        'id': input.taskId,
        'input': jsonEncode(input.toJson()),
        'status': TaskStatus.queued.name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      final assets = [
        ...input.references,
        if (input.mask != null) input.mask!,
        if (input.markup != null) input.markup!,
      ];
      for (var i = 0; i < assets.length; i++) {
        final role = assets[i] == input.mask
            ? 'mask'
            : assets[i] == input.markup
            ? 'markup'
            : 'input';
        await tx.insert('task_assets', {
          'task_id': input.taskId,
          'asset_id': assets[i].id,
          'role': role,
          'position': i,
          'attempt': 0,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    notifyListeners();
  }

  Future<List<StudioTask>> tasks() => _tasks();

  Future<StudioTask?> task(String id) async => (await _tasks(id: id)).firstOrNull;

  Future<List<StudioTask>> queuedTasks() => _tasks(queuedOnly: true);

  Future<List<StudioTask>> _tasks({bool queuedOnly = false, String? id}) async {
    return db.transaction((tx) async {
      final rows = await tx.query(
        'tasks',
        where: queuedOnly ? "status = 'queued' AND deleted_at IS NULL" : (id == null ? null : 'id = ?'),
        whereArgs: id == null ? null : [id],
        orderBy: 'created_at DESC',
      );
      final outputs = <String, List<ImageAsset>>{};
      if (!queuedOnly && rows.isNotEmpty) {
        for (final row in await tx.rawQuery(
          "SELECT r.task_id, a.data FROM task_assets r JOIN assets a ON a.id = r.asset_id WHERE r.role = 'output'"
          "${id == null ? '' : ' AND r.task_id = ?'} ORDER BY r.attempt, r.position",
          id == null ? null : [id],
        )) {
          outputs
              .putIfAbsent(row['task_id'] as String, () => [])
              .add(ImageAsset.fromJson(decodeObject(row['data'] as String)));
        }
      }
      return [
        for (final row in rows)
          StudioTask(
            input: GenerationInput.fromJson(
              decodeObject(row['input'] as String),
            ),
            status: TaskStatus.values.byName(row['status'] as String),
            createdAt: DateTime.parse(row['created_at'] as String),
            outputs: outputs[row['id']] ?? [],
            favorite: row['favorite'] == 1,
            categoryId: row['category_id'] as String?,
            deletedAt: row['deleted_at'] == null
                ? null
                : DateTime.parse(row['deleted_at'] as String),
            error: row['error'] as String?,
            attempt: row['attempt'] as int,
          ),
      ];
    });
  }

  Future<int?> startAttempt(String id) async {
    final attempt = await db.transaction((tx) async {
      final rows = await tx.query(
        'tasks',
        columns: ['attempt'],
        where: "id = ? AND status = 'queued' AND deleted_at IS NULL",
        whereArgs: [id],
      );
      if (rows.isEmpty) return null;
      final previous = rows.single['attempt'] as int;
      final checkpoints = await _remoteCheckpoints(tx, id, previous);
      final number = checkpoints.isEmpty ? previous + 1 : previous;
      await tx.update(
        'tasks',
        {'status': 'running', 'attempt': number, 'error': null},
        where: 'id = ?',
        whereArgs: [id],
      );
      if (checkpoints.isNotEmpty) return number;
      await tx.insert('attempts', {
        'task_id': id,
        'number': number,
        'started_at': DateTime.now().toUtc().toIso8601String(),
      });
      return number;
    });
    if (attempt != null) notifyListeners();
    return attempt;
  }

  Future<bool> transition(
    String id,
    TaskStatus from,
    TaskStatus to, {
    String? error,
  }) async {
    final changed = await db.update(
      'tasks',
      {'status': to.name, 'error': error},
      where: 'id = ? AND status = ?',
      whereArgs: [id, from.name],
    );
    if (changed > 0) notifyListeners();
    return changed > 0;
  }

  Future<void> recoverInterrupted() async {
    await db.transaction((tx) async {
      final tasks = await tx.query('tasks', where: "status = 'running'");
      for (final task in tasks) {
        final id = task['id'] as String;
        final attempt = task['attempt'] as int;
        final recoverable = task['deleted_at'] == null &&
            (await _remoteCheckpoints(tx, id, attempt)).isNotEmpty;
        await tx.update('tasks', {
          'status': recoverable ? 'queued' : 'interrupted',
          'error': recoverable ? null : '应用执行已中断，供应商可能已接收并扣费，请先核对远端结果',
        }, where: 'id = ?', whereArgs: [id]);
      }
    });
    notifyListeners();
  }

  Future<Map<int, String>> remoteCheckpoints(String id, int attempt) =>
      _remoteCheckpoints(db, id, attempt);

  Future<Map<int, String>> _remoteCheckpoints(DatabaseExecutor executor, String id, int attempt) async {
    final rows = await executor.query('attempts', columns: ['metadata'],
        where: 'task_id = ? AND number = ? AND ended_at IS NULL', whereArgs: [id, attempt]);
    if (rows.isEmpty) return {};
    final raw = decodeObject(rows.single['metadata'] as String)['remote_checkpoints'];
    if (raw is! Map) return {};
    final result = <int, String>{};
    for (final entry in raw.entries) {
      final position = int.tryParse(entry.key.toString());
      final remoteId = entry.value;
      if (position == null || position < 0 || remoteId is! String || remoteId.isEmpty) return {};
      result[position] = remoteId;
    }
    return result;
  }

  Future<void> updateTask(String id, Map<String, Object?> changes) async {
    const allowed = {
      'status',
      'favorite',
      'category_id',
      'deleted_at',
      'error',
      'attempt',
      'original_input',
    };
    if (changes.keys.any((k) => !allowed.contains(k)))
      throw ArgumentError('不允许修改任务字段');
    final deleting = changes['deleted_at'] != null;
    final changed = await db.update(
      'tasks',
      changes,
      where: deleting ? 'id = ? AND status NOT IN (?, ?)' : 'id = ?',
      whereArgs: deleting ? [id, 'running', 'queued'] : [id],
    );
    if (deleting && changed == 0) throw StateError('请先停止任务');
    notifyListeners();
  }

  /// 固定本次预处理后实际送给供应商的输入；重试与进程恢复沿用它，草稿仍读原始 input。
  Future<void> pinTaskInput(String id, GenerationInput effective) async {
    await db.update(
      'tasks',
      {'original_input': jsonEncode(effective.toJson())},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 已固定的实际输入；没有预处理时返回任务原始输入。
  /// 按 ID 取已登记资产；后处理重试需要从断点源图继续。
  Future<ImageAsset?> asset(String id) async {
    final rows = await db.query('assets', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty
        ? null
        : ImageAsset.fromJson(decodeObject(rows.single['data'] as String));
  }

  Future<GenerationInput> pinnedInput(StudioTask task) async {
    final rows = await db.query(
      'tasks',
      columns: ['original_input'],
      where: 'id = ?',
      whereArgs: [task.input.taskId],
    );
    final raw = rows.isEmpty ? null : rows.single['original_input'] as String?;
    if (raw == null || raw.isEmpty) return task.input;
    return GenerationInput.fromJson(
      Map<String, dynamic>.from(decodeObject(raw)),
    );
  }

  /// 登记本地处理产物：派生任务不收费、不伪装供应商，源图与结果都留引用。
  Future<String> recordDerivedImage({
    required ImageAsset source,
    required ImageAsset result,
    required ProcessingStep step,
  }) async {
    final key =
        'derived:${sha256.convert(utf8.encode('${source.id}|${step.pluginId}@${step.version}/${step.processorId}|${jsonEncode(step.params)}|${result.id}'))}';
    final cached = await setting(key);
    if (cached?['taskId'] is String) return cached!['taskId'] as String;

    final parentRows = await db.rawQuery(
      'SELECT task_id FROM task_assets WHERE asset_id = ? ORDER BY task_id LIMIT 1',
      [source.id],
    );
    final taskId = newId();
    final provider = ProviderConfig(
      id: 'local.${step.pluginId}',
      name: '本地处理',
      baseUrl: 'local://plugin',
      adapterId: step.pluginId,
      adapterVersion: step.version,
      enabled: false,
      allowHttp: false,
      // 幂等键只留哈希，参数与版本快照必须另存一份才能回溯。
      pluginConfig: {'step': step.toJson()},
    );
    final input = GenerationInput(
      taskId: taskId,
      provider: provider,
      prompt: '本地处理：${step.processorId}',
      params: const GenerationParams(count: 1),
      references: [source],
      parentTaskId: parentRows.isEmpty
          ? null
          : parentRows.single['task_id'] as String?,
      parentAssetId: source.id,
    );
    await db.transaction((tx) async {
      await tx.insert('tasks', {
        'id': taskId,
        'input': jsonEncode(input.toJson()),
        'status': TaskStatus.done.name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await tx.insert('task_assets', {
        'task_id': taskId,
        'asset_id': source.id,
        'role': 'input',
        'position': 0,
        'attempt': 0,
      });
      await tx.insert('task_assets', {
        'task_id': taskId,
        'asset_id': result.id,
        'role': 'output',
        'position': 0,
        'attempt': 0,
      });
      await tx.insert('settings', {
        'key': key,
        'value': jsonEncode({
          'taskId': taskId,
          'source': source.id,
          'result': result.id,
          'pluginId': step.pluginId,
          'version': step.version,
          'processorId': step.processorId,
          'step': step.toJson(),
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    notifyListeners();
    return taskId;
  }

  /// 记录后处理失败位置：重试只重跑本地处理，不再调用收费生成。
  Future<void> savePipelineState(
    String taskId, {
    required String stage,
    required int position,
    required int attempt,
    required int step,
    String? sourceAssetId,
    String? message,
    int? expected,
  }) async {
    await db.insert('pipeline_state', {
      'task_id': taskId,
      'stage': stage,
      'position': position,
      'attempt': attempt,
      'step': step,
      'source_asset_id': sourceAssetId,
      'message': message,
      'expected': expected,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<PipelineFailure?> pipelineFailure(String taskId) async {
    final rows = await db.query(
      'pipeline_state',
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return PipelineFailure(
      stage: row['stage'] as String,
      position: row['position'] as int,
      attempt: row['attempt'] as int,
      step: row['step'] as int,
      sourceAssetId: row['source_asset_id'] as String?,
      message: row['message'] as String?,
      expected: row['expected'] as int?,
    );
  }

  Future<void> clearPipelineState(String taskId) async {
    await db.delete(
      'pipeline_state',
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
  }

  /// 某次尝试已落盘的原始输出，后处理重试基于它继续。
  Future<List<ImageAsset>> attemptOutputs(String taskId, int attempt) async {
    final rows = await db.rawQuery(
      "SELECT a.data FROM task_assets r JOIN assets a ON a.id = r.asset_id WHERE r.task_id = ? AND r.role = 'output' AND r.attempt = ? ORDER BY r.position",
      [taskId, attempt],
    );
    return [
      for (final row in rows)
        ImageAsset.fromJson(decodeObject(row['data'] as String)),
    ];
  }

  Future<bool> attachOutput(
    String id,
    ImageAsset asset,
    int attempt,
    int position, {
    bool requireRunning = false,
  }) async {
    final attached = await db.transaction((tx) async {
      if (requireRunning) {
        final rows = await tx.query(
          'tasks',
          columns: ['status', 'attempt'],
          where: 'id = ?',
          whereArgs: [id],
        );
        if (rows.isEmpty ||
            rows.single['status'] != 'running' ||
            rows.single['attempt'] != attempt)
          return false;
      }
      await tx.insert('task_assets', {
        'task_id': id,
        'asset_id': asset.id,
        'role': 'output',
        'position': position,
        'attempt': attempt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      return true;
    });
    if (attached) notifyListeners();
    return attached;
  }

  /// 挂上本次预处理的派生输入图，保留引用以便清理与备份。
  Future<void> attachDerivedInput(
    String id,
    ImageAsset asset,
    int attempt,
    int position,
  ) async {
    await db.insert('task_assets', {
      'task_id': id,
      'asset_id': asset.id,
      'role': 'derived',
      'position': position,
      'attempt': attempt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    notifyListeners();
  }

  static const draftRevisionKey = 'internal:draft-revision';

  Future<({Map<String, dynamic>? draft, String? revision})> readDraft() =>
      db.transaction((tx) async => (
        draft: await _setting(tx, 'draft'),
        revision: (await _setting(tx, draftRevisionKey))?['id'] as String?,
      ));

  Future<void> saveDraft(Map<String, dynamic> draft, String? revision) async {
    await db.transaction((tx) async {
      if ((await _setting(tx, draftRevisionKey))?['id'] != revision) return;
      await tx.insert('settings', {'key': 'draft', 'value': jsonEncode(draft)},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
  Future<void> saveSetting(String key, Map<String, dynamic> value) async {
    await db.insert('settings', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> setting(String key) => _setting(db, key);

  Future<Map<String, dynamic>?> _setting(DatabaseExecutor executor, String key) async {
    final rows = await executor.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : decodeObject(rows.single['value'] as String);
  }

  Future<List<Map<String, Object?>>> categories() =>
      db.query('categories', orderBy: 'name');
  Future<void> saveCategory(String id, String name) async {
    if (name.trim().isEmpty) throw const FormatException('分类名称不能为空');
    await db.insert('categories', {
      'id': id,
      'name': name.trim(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deleteCategory(String id) async {
    await db.transaction((tx) async {
      await tx.update(
        'tasks',
        {'category_id': null},
        where: 'category_id = ?',
        whereArgs: [id],
      );
      await tx.delete('categories', where: 'id = ?', whereArgs: [id]);
    });
    notifyListeners();
  }

  Future<List<Map<String, Object?>>> prompts() =>
      db.query('prompts', orderBy: 'updated_at DESC');
  Future<void> savePrompt(String id, String title, String content) async {
    if (content.trim().isEmpty) throw const FormatException('提示词不能为空');
    await db.insert('prompts', {
      'id': id,
      'title': title.trim(),
      'content': content,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> deletePrompt(String id) async {
    await db.delete('prompts', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> purgeTask(String id) async {
    await db.transaction((tx) async {
      final rows = await tx.query('tasks', columns: ['status', 'deleted_at'], where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      if (rows.single['deleted_at'] == null || ['running', 'queued'].contains(rows.single['status'])) {
        throw StateError('只能彻底删除回收站内已停止的任务');
      }
      await tx.delete(
        'tasks',
        where: 'id = ? AND deleted_at IS NOT NULL AND status NOT IN (?, ?)',
        whereArgs: [id, 'running', 'queued'],
      );
      await _prunePendingDownloads(tx);
    });
    // 图片延迟清理，避免破坏草稿与仍引用源图的后续任务。
    notifyListeners();
  }

  Future<void> pruneOrphanAssets() async {
    await db.transaction((tx) async {
      if ((firstIntValue(
                await tx.rawQuery(
                  "SELECT COUNT(*) FROM tasks WHERE status IN ('queued', 'running')",
                ),
              ) ??
              0) >
          0)
        return;
      final retained = <String>{};
      void collect(dynamic value) {
        if (value is Map) {
          if (value['id'] is String && value['path'] is String)
            retained.add(value['id'] as String);
          for (final child in value.values) {
            collect(child);
          }
        } else if (value is List) {
          for (final child in value) {
            collect(child);
          }
        }
      }

      for (final row in await tx.query('settings')) {
        collect(jsonDecode(row['value'] as String));
      }
      for (final row in await tx.query('tasks', columns: ['input'])) {
        collect(jsonDecode(row['input'] as String));
      }
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      final rows = await tx.rawQuery(
        'SELECT a.* FROM assets a WHERE NOT EXISTS (SELECT 1 FROM task_assets r WHERE r.asset_id = a.id)',
      );
      for (final row in rows) {
        if (retained.contains(row['id'])) continue;
        final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
        if (kIsWeb) {
          _validateAssetPath(asset);
          final rows = await tx.query(
            'asset_bytes',
            columns: ['created_at'],
            where: 'asset_id = ?',
            whereArgs: [asset.id],
          );
          if (rows.isNotEmpty &&
              (rows.single['created_at'] as int) > cutoff.millisecondsSinceEpoch) {
            continue;
          }
        } else {
          final file = fileFor(asset);
          if (await file.exists()) {
            if ((await file.lastModified()).isAfter(cutoff)) continue;
            await file.delete();
          }
        }
        // Web 字节通过外键与元数据在同一事务中清理。
        await tx.delete('assets', where: 'id = ?', whereArgs: [row['id']]);
      }
    });
  }

  Future<void> pruneExpired() async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 15))
        .toIso8601String();
    await db.transaction((tx) async {
      await tx.delete('errors', where: 'created_at < ?', whereArgs: [cutoff]);
      await tx.delete(
        'tasks',
        where: 'deleted_at < ? AND status NOT IN (?, ?)',
        whereArgs: [cutoff, 'running', 'queued'],
      );
      await _prunePendingDownloads(tx);
    });
    await pruneOrphanAssets();
    notifyListeners();
  }

  Future<void> _prunePendingDownloads(DatabaseExecutor tx) async {
    final keys = await tx.query('settings', columns: ['key', 'value'], where: "key LIKE 'pending:%'");
    if (keys.isEmpty) return;
    final ids = {for (final row in await tx.query('tasks', columns: ['id'])) row['id']};
    for (final row in keys) {
      final pending = decodeObject(row['value'] as String);
      if (!ids.contains(pending['taskId'])) {
        await tx.delete('settings', where: 'key = ?', whereArgs: [row['key']]);
      }
    }
  }
  void refresh() => notifyListeners();

  Future<void> resumeRemoteTask(String id) async {
    await db.transaction((tx) async {
      final rows = await tx.query('tasks', columns: ['attempt'],
          where: "id = ? AND deleted_at IS NULL AND status IN ('error', 'partialError', 'interrupted')", whereArgs: [id]);
      if (rows.isEmpty || (await _remoteCheckpoints(tx, id, rows.single['attempt'] as int)).isEmpty) {
        throw StateError('没有可继续查询的远端任务');
      }
      await tx.update('tasks', {'status': 'queued', 'error': null}, where: 'id = ?', whereArgs: [id]);
    });
    notifyListeners();
  }
  Future<void> retryTask(String id) async {
    final rows = await db.query(
      'tasks',
      columns: ['input'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isNotEmpty &&
        GenerationInput.fromJson(decodeObject(rows.single['input'] as String))
            .provider
            .id
            .startsWith('local.'))
      throw StateError('本地处理不消耗额度，无需重新生成');
    await db.transaction((tx) async {
      final changed = await tx.update(
        'tasks',
        {'status': 'queued', 'error': null},
        where: 'id = ? AND deleted_at IS NULL AND status NOT IN (?, ?)',
        whereArgs: [id, 'queued', 'running'],
      );
      if (changed == 0) throw StateError('任务正在执行或已进入回收站');
      await tx.update('attempts', {'ended_at': DateTime.now().toUtc().toIso8601String()},
          where: 'task_id = ? AND ended_at IS NULL', whereArgs: [id]);
    });
    notifyListeners();
  }

  Future<void> close() => db.close();
}

const _taskAssetsSchema = 'CREATE TABLE task_assets(task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, asset_id TEXT NOT NULL REFERENCES assets(id), role TEXT NOT NULL, position INTEGER NOT NULL, attempt INTEGER NOT NULL, PRIMARY KEY(task_id,asset_id,role,attempt,position))';
const _maxAssetBytes = 64 * 1024 * 1024;
final _assetPath = RegExp(r'^assets/[a-f0-9]{64}\.(png|jpeg|webp|gif|svg)$');

void _validateAssetPath(ImageAsset asset) {
  if (!_assetPath.hasMatch(asset.path) ||
      (kIsWeb && !asset.path.startsWith('assets/${asset.hash}.'))) {
    throw const FormatException('非法图片路径');
  }
}
String _hash(Uint8List bytes) => sha256.convert(bytes).toString();

/// 追加表：只在 open 时以 IF NOT EXISTS 建立，不改共享 schema 版本。
const _pipelineStateSchema =
    'CREATE TABLE IF NOT EXISTS pipeline_state(task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE, stage TEXT NOT NULL, position INTEGER NOT NULL, attempt INTEGER NOT NULL, step INTEGER NOT NULL, source_asset_id TEXT, message TEXT, expected INTEGER, updated_at TEXT NOT NULL)';

/// 一次失败的本地处理位置；retry 据此只重跑该阶段。
class PipelineFailure {
  const PipelineFailure({
    required this.stage,
    required this.position,
    required this.attempt,
    required this.step,
    this.sourceAssetId,
    this.message,
    this.expected,
  });
  final String stage;
  final int position, attempt, step;
  final String? sourceAssetId, message;

  /// 原始生图那一次尝试的期望张数；本地重试不改写这个契约。
  final int? expected;
}
