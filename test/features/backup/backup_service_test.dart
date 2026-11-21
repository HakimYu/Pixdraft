import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/backup/backup_encryption.dart';
import 'package:image_gen/features/backup/backup_service.dart';
import 'package:image_gen/features/backup/backup_options.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

Uint8List _chunk(String type, List<int> data) {
  final payload = <int>[...ascii.encode(type), ...data];
  return Uint8List.fromList([
    ..._u32(data.length),
    ...payload,
    ..._u32(_crc32(payload)),
  ]);
}

Uint8List pngBytes(int seed) {
  final r = seed % 256;
  final g = (seed * 7) % 256;
  final b = (seed * 13) % 256;
  final compressed = ZLibCodec().encode(<int>[0, r, g, b, 255]);
  final ihdr = <int>[..._u32(1), ..._u32(1), 8, 6, 0, 0, 0];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    ..._chunk('IHDR', ihdr),
    ..._chunk('IDAT', compressed),
    ..._chunk('IEND', const []),
  ]);
}

Map<String, dynamic> manifestOf(Uint8List zip) {
  final archive = ZipDecoder().decodeBytes(zip);
  final file = archive.files.firstWhere((f) => f.name == 'manifest.json');
  return jsonDecode(utf8.decode(List<int>.from(file.content as List)))
      as Map<String, dynamic>;
}

Uint8List zipWith(Map<String, dynamic> manifest, Map<String, List<int>> files) {
  final archive = Archive()
    ..add(
      ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))),
    );
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List rezip(Uint8List original, Map<String, dynamic> manifest) {
  final source = ZipDecoder().decodeBytes(original);
  final archive = Archive();
  for (final file in source) {
    final name = file.name;
    final bytes = name == 'manifest.json'
        ? utf8.encode(jsonEncode(manifest))
        : List<int>.from(file.content as List);
    archive.add(ArchiveFile.bytes(name, bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

Future<StudioStore> openStore(Directory directory) =>
    StudioStore.open(factory: databaseFactoryFfi, directory: directory);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureValues = <String, String>{};
  bool readFailure = false, writeFailure = false;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureChannel, (call) async {
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : <String, dynamic>{};
        switch (call.method) {
          case 'read':
            if (readFailure)
              throw PlatformException(code: 'secure_storage_unavailable');
            return secureValues[args['key']];
          case 'write':
            if (writeFailure)
              throw PlatformException(code: 'secure_storage_unavailable');
            secureValues[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            secureValues.remove(args['key']);
            return null;
          case 'readAll':
            if (readFailure)
              throw PlatformException(code: 'secure_storage_unavailable');
            return Map<String, String>.from(secureValues);
          case 'deleteAll':
            secureValues.clear();
            return null;
          case 'containsKey':
            return secureValues.containsKey(args['key']);
        }
        return null;
      });
  sqfliteFfiInit();

  late Directory directoryA;
  late Directory directoryB;
  late StudioStore a;
  late StudioStore b;

  setUp(() async {
    secureValues.clear();
    readFailure = writeFailure = false;
    directoryA = await Directory.systemTemp.createTemp('image-gen-backup-a-');
    directoryB = await Directory.systemTemp.createTemp('image-gen-backup-b-');
    a = await openStore(directoryA);
    b = await openStore(directoryB);
  });

  tearDown(() async {
    await a.close();
    await b.close();
    await directoryA.delete(recursive: true);
    await directoryB.delete(recursive: true);
  });

  const provider = ProviderConfig(
    id: 'p1',
    name: '主供应商',
    baseUrl: 'https://example.com/v1',
    models: ['gpt-image-1', 'image-extra'],
  );

  test('Web 单文件备份可加密、预检并恢复，默认排除凭据', () async {
    const password = 'example-passphrase';
    await a.saveProvider(provider, key: 'private');
    final backup = await BackupService(a).exportWebBackup(
      options: const BackupOptions(password: password),
    );
    expect(backup.fileName, endsWith('.igbackup'));
    final zip = await decryptBackup(backup.bytes, password);
    expect(manifestOf(zip)['containsApiKeys'], isFalse);
    final service = BackupService(b);
    await expectLater(service.prepareWebImport(backup.bytes, password: 'wrong'),
        throwsA(isA<BackupException>()));
    final plan = await service.prepareWebImport(backup.bytes, password: password);
    expect(plan.preview.providersAdded, 1);
    await plan.commit();
    expect(await b.db.query('providers'), hasLength(1));
  });

  test('Web 预检拒绝超限包及不安全的 ZIP 路径', () async {
    final service = BackupService(b);
    await expectLater(service.prepareWebImport(Uint8List(webBackupMaxBytes + 1)),
        throwsA(isA<BackupException>()));
    await expectLater(service.prepareWebImport(zipWith({}, {'../outside': [1]})),
        throwsA(isA<BackupException>()));
    expect(await b.db.query('assets'), isEmpty);
  });
  test('超过 512 MiB 的明文单包可取消预览并完整恢复', () async {
    const mib = 1024 * 1024;
    final staging = Directory('${directoryB.path}/backup-staging');
    final assets = <ImageAsset>[];
    await Directory('${directoryA.path}/assets').create();
    // 一个合法 PNG 文本块反复使用，避免 fixture 生成时聚合所有图片。
    final text = Uint8List(mib)..fillRange(8, mib, 65);
    text.setRange(0, 7, ascii.encode('Comment'));
    final chunk = _chunk('tEXt', text);
    const chunkCount = 57;
    for (var i = 0; i < 9; i++) {
      final png = pngBytes(i);
      final end = png.length - 12;
      final temp = File('${directoryA.path}/fixture.png');
      final writer = await temp.open(mode: FileMode.write);
      try {
        await writer.writeFrom(png, 0, end);
        for (var j = 0; j < chunkCount; j++) {
          await writer.writeFrom(chunk);
        }
        await writer.writeFrom(png, end);
      } finally {
        await writer.close();
      }
      final hash = (await sha256.bind(temp.openRead()).first).toString();
      final asset = ImageAsset(
        id: hash,
        path: 'assets/$hash.png',
        hash: hash,
        mime: 'image/png',
        bytes: await temp.length(),
      );
      await temp.rename(a.fileFor(asset).path);
      await a.db.insert('assets', {
        'id': hash,
        'hash': hash,
        'data': jsonEncode(asset.toJson()),
      });
      assets.add(asset);
    }
    await a.enqueue(GenerationInput(
      taskId: 'large',
      provider: provider,
      prompt: '大包恢复',
      params: const GenerationParams(),
      references: [assets.first],
    ));
    for (var i = 1; i < assets.length; i++) {
      await a.attachOutput('large', assets[i], 0, i - 1);
    }
    await a.updateTask('large', {'status': 'done'});
    final [file] = await BackupService(a, directoryA).writeExportFiles(
      options: const BackupOptions(providers: false),
    );
    final bytes = await file.length();
    expect(bytes, greaterThan(512 * mib));
    print('大包验收：$bytes 字节');

    final service = BackupService(b, directoryB);
    final cancelled = await service.prepareImportFiles([file]);
    expect(cancelled.preview.assets, assets.length);
    await service.recoverInterruptedImports();
    await cancelled.dispose();
    expect(await staging.list().isEmpty, isTrue);
    expect(await b.db.query('tasks'), isEmpty);
    expect(await b.db.query('assets'), isEmpty);

    final plan = await service.prepareImportFiles([file]);
    final result = await plan.commit();
    expect(result.preview.tasks, 1);
    expect(result.preview.assets, assets.length);
    expect((await b.tasks()).single.input.references.single.id, assets.first.id);
    expect((await b.attemptOutputs('large', 0)).map((a) => a.id),
        assets.skip(1).map((a) => a.id));
    for (final asset in assets) {
      expect((await sha256.bind(b.fileFor(asset).openRead()).first).toString(),
          asset.hash);
    }
    expect(await staging.list().isEmpty, isTrue);
    expect(await file.exists(), isTrue);
  }, skip: Platform.environment['IMAGE_GEN_LARGE_BACKUP_TEST'] != '1',
      timeout: const Timeout(Duration(minutes: 5)));
  test('排除作品范围时不读取本地图片，也不因损坏图片阻断导出', () async {
    await Directory('${a.root.path}/assets').create(recursive: true);
    for (var i = 0; i < 9; i++) {
      final hash = '$i' * 64;
      final asset = ImageAsset(
        id: hash,
        hash: hash,
        path: 'assets/$hash.png',
        mime: 'image/png',
        bytes: 64 * 1024 * 1024,
      );
      final file = await a.fileFor(asset).open(mode: FileMode.write);
      await file.truncate(asset.bytes);
      await file.close();
      await a.db.insert('assets', {
        'id': hash,
        'hash': hash,
        'data': jsonEncode(asset.toJson()),
      });
    }
    final output = await BackupService(
      a,
      directoryA,
    ).writeExportFile(options: const BackupOptions(works: false));
    expect(await output.exists(), isTrue);
    await output.delete();
    final first = await a.db.query('assets', limit: 1);
    final asset = ImageAsset.fromJson(
      decodeObject(first.single['data'] as String),
    );
    final file = await a.fileFor(asset).open(mode: FileMode.append);
    await file.truncate(64 * 1024 * 1024 + 1);
    await file.close();
    final second = await BackupService(
      a,
      directoryA,
    ).writeExportFile(options: const BackupOptions(works: false));
    expect(await second.exists(), isTrue);
    await second.delete();
  });
  Future<Uint8List> seed(StudioStore store, {bool duplicateOutput = false}) async {
    await store.saveProvider(provider, key: 'sk-secret');
    await store.saveCategory('c1', '分类');
    await store.savePrompt('pr1', '标题', '提示词内容');
    await store.saveSetting('draft.params', {
      'size': '1024x1024',
      'apiKey': 'sk-secret',
    });
    final input = await store.saveAsset(pngBytes(1), 'image/png');
    final mask = await store.saveAsset(pngBytes(2), 'image/png');
    final markup = await store.saveAsset(pngBytes(3), 'image/png');
    await store.enqueue(
      GenerationInput(
        taskId: 't1',
        provider: provider,
        prompt: '一只猫',
        params: const GenerationParams(
          count: 2,
          format: 'webp',
          compression: 80,
        ),
        references: [input],
        mask: mask,
        markup: markup,
      ),
    );
    await store.updateTask('t1', {
      'status': 'done',
      'favorite': 1,
      'category_id': 'c1',
    });
    final output = await store.saveAsset(pngBytes(4), 'image/png');
    await store.attachOutput('t1', output, 0, 0);
    if (duplicateOutput) await store.attachOutput('t1', output, 0, 1);
    final now = DateTime.now().toUtc().toIso8601String();
    await store.db.insert('attempts', {
      'task_id': 't1',
      'number': 0,
      'started_at': now,
      'ended_at': now,
      'metadata': jsonEncode({'note': 'local'}),
      'error': null,
    });
    return (await BackupService(store).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true))).bytes;
  }

  test('默认文件备份保留供应商配置但省略密钥', () async {
    await seed(a);
    await a.saveSetting('apiKey', {'value': 'standalone-secret'});
    final service = BackupService(a, directoryA);
    final file = await service.writeExportFile();
    final manifest = manifestOf(await file.readAsBytes());
    expect(manifest['providers'], hasLength(1));
    expect(manifest['containsApiKeys'], isFalse);
    expect(manifest['credentials'], isEmpty);
    expect(manifest['settings'], isNot(contains('apiKey')));
    expect(manifest['settings']['draft.params'], {'size': '1024x1024'});
    expect(manifestOf((await service.exportWebBackup(options: BackupOptions(trash: true))).bytes)['credentials'], isEmpty);
  });

  test('单个分包可经文件入口恢复', () async {
    final service = BackupService(a, directoryA);
    final files = await service.writeExportFiles(
      options: const BackupOptions(works: false, split: true),
    );
    expect(files, hasLength(1));
    final importer = BackupService(b, directoryB);
    expect(await importer.isEncryptedBackupFiles(files), isFalse);
    final plan = await importer.prepareImportFiles(files);
    await plan.commit();
  });
  test('完整本地导出包含密钥，roundtrip 保留任务关系并跳过重复导入', () async {
    final zip = await seed(a, duplicateOutput: true);
    final manifest = manifestOf(zip);
    expect(manifest['format'], 'image-gen.backup');
    expect(manifest['version'], 2);
    expect(manifest['containsApiKeys'], isTrue);
    expect(manifest['credentials'], {'provider:p1': 'sk-secret'});
    expect(
      (manifest['providers'] as List).single.containsKey('apiKey'),
      isFalse,
    );

    await b.credentials.deleteAll();
    final first = await BackupService(b).importBackup(zip);
    expect(first.preview.tasks, 1);
    expect(first.preview.assets, 4);
    final tasks = await b.tasks();
    expect(tasks, hasLength(1));
    final task = tasks.single;
    expect(task.input.prompt, '一只猫');
    expect(task.input.params.count, 2);
    expect(task.input.params.format, 'webp');
    expect(task.input.params.compression, 80);
    expect(task.input.references, hasLength(1));
    expect(task.input.mask, isNotNull);
    expect(task.input.markup, isNotNull);
    expect(task.outputs, hasLength(2));
    expect(task.outputs.first.id, task.outputs.last.id);
    expect(task.status, TaskStatus.done);
    expect(task.favorite, isTrue);
    expect(task.categoryId, 'c1');
    final relations = await b.db.query('task_assets');
    expect(
      relations.map((r) => r['role']),
      containsAll(['input', 'mask', 'markup', 'output']),
    );
    expect(await b.db.query('attempts'), hasLength(1));
    expect(await b.setting('draft.params'), {
      'size': '1024x1024',
      'apiKey': 'sk-secret',
    });
    final providers = await b.providers();
    expect(providers.single.id, 'p1');
    expect(providers.single.enabledModels, provider.enabledModels);
    expect(
      (await b.tasks()).single.input.provider.enabledModels,
      provider.enabledModels,
    );
    expect(await b.apiKey('p1'), 'sk-secret');
    expect(await b.prompts(), hasLength(1));
    expect(await b.categories(), hasLength(1));

    final assets = await b.db.query('assets');
    expect(assets, hasLength(4));
    for (final row in assets) {
      final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
      expect(await File('${b.root.path}/${asset.path}').exists(), isTrue);
    }

    final second = await BackupService(b).importBackup(zip);
    expect(second.preview.duplicateTasks, 1);
    expect(second.preview.tasks, 0);
    expect(await b.tasks(), hasLength(1));
    expect(await b.db.query('assets'), hasLength(4));
  });

  test('文件导出不读未选凭据并可经文件入口恢复', () async {
    await seed(a);
    readFailure = true;
    final file = await BackupService(a, directoryA).writeExportFile(
      options: const BackupOptions(
        works: true,
        providers: false,
        prompts: false,
        settings: false,
        errors: false,
      ),
    );
    expect(await file.exists(), isTrue);
    final plan = await BackupService(b, directoryB).prepareImportFile(file);
    expect(plan.preview.tasks, 1);
    await plan.commit();
    expect(await b.tasks(), hasLength(1));
    expect(await b.providers(), isEmpty);
    expect(await file.exists(), isTrue);
    readFailure = false;
  });

  test('服务层分包支持乱序选择并经同一文件恢复流程导入', () async {
    await a.saveProvider(provider, key: 'secret');
    final progress = <(String, int, int)>[];
    final files = await BackupService(a, directoryA).writeExportFiles(
      options: const BackupOptions(works: false, split: true, password: 'test-password'),
      partSize: 128,
      onProgress: (stage, completed, total) => progress.add((stage, completed, total)),
    );
    expect(files.length, greaterThan(1));
    expect(progress.first, ('打包备份', 0, 1));
    expect(progress[1], ('打包备份', 1, 1));
    expect(progress.map((event) => event.$1).toSet(), {'打包备份', '加密备份', '拆分备份'});
    expect(progress.where((event) => event.$1 == '加密备份'), [('加密备份', 0, 1), ('加密备份', 1, 1)]);
    expect(progress.last.$2, progress.last.$3);
    expect(progress.last.$1, '拆分备份');
    final plan = await BackupService(
      b,
      directoryB,
    ).prepareImportFiles(files.reversed.toList(), partSize: 128, password: 'test-password');
    expect(plan.preview.providersAdded, 1);
    await plan.commit();
    expect((await b.providers()).single.id, provider.id);
    for (final file in files) {
      expect(await file.exists(), isTrue);
      await file.delete();
    }
  });

  test('全空导出选项明确拒绝', () async {
    await expectLater(
      BackupService(a, directoryA).writeExportFile(
        options: const BackupOptions(
          works: false,
          providers: false,
          prompts: false,
          settings: false,
          errors: false,
        ),
      ),
      throwsA(isA<BackupException>()),
    );
  });

  test('同 ID 不同内容的供应商和任务重新映射，不覆盖本地数据', () async {
    final zip = await seed(a);
    await b.saveProvider(
      const ProviderConfig(
        id: 'p1',
        name: '本地供应商',
        baseUrl: 'https://local.example/v1',
      ),
    );
    await b.enqueue(
      const GenerationInput(
        taskId: 't1',
        provider: ProviderConfig(
          id: 'p1',
          name: '本地供应商',
          baseUrl: 'https://local.example/v1',
        ),
        prompt: '本地任务',
        params: GenerationParams(),
      ),
    );
    await b.updateTask('t1', {'status': 'done'});

    final result = await BackupService(b).importBackup(zip);
    expect(result.preview.remappedTasks, 1);
    expect(result.preview.providersAdded, 1);
    final tasks = await b.tasks();
    expect(tasks, hasLength(2));
    final imported = tasks.firstWhere((task) => task.input.prompt == '一只猫');
    expect(imported.input.taskId, isNot('t1'));
    expect(imported.input.provider.baseUrl, 'https://example.com/v1');
    expect(imported.input.provider.id, isNot('p1'));
    expect(
      (await b.tasks())
          .firstWhere((task) => task.input.taskId == 't1')
          .input
          .prompt,
      '本地任务',
    );
    expect(await b.providers(), hasLength(2));
  });

  test('拒绝 ZIP 路径逃逸且不写入任何数据', () async {
    final zip = await seed(a);
    final manifest = manifestOf(zip);
    final malicious = zipWith(manifest, {
      'manifest.json': utf8.encode(jsonEncode(manifest)),
      'assets/../../evil.png': pngBytes(9),
    });
    await expectLater(
      BackupService(b).prepareImport(malicious),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('非法路径'),
        ),
      ),
    );
    expect(await b.tasks(), isEmpty);
    expect(await b.db.query('assets'), isEmpty);
  });

  test('任务引用缺失图片时失败回滚，不损现有数据', () async {
    final zip = await seed(a);
    final manifest = manifestOf(zip);
    (manifest['taskAssets'] as List).add({
      'task_id': 't1',
      'asset_id': 'missing',
      'role': 'input',
      'position': 99,
      'attempt': 0,
    });
    await expectLater(
      BackupService(b).importBackup(rezip(zip, manifest)),
      throwsA(isA<BackupException>()),
    );
    expect(await b.tasks(), isEmpty);
    expect(await b.db.query('assets'), isEmpty);
    expect(await b.db.query('providers'), isEmpty);
  });

  test('有任务运行或排队时禁止导入', () async {
    final zip = await seed(a);
    await b.saveProvider(provider);
    await b.enqueue(
      const GenerationInput(
        taskId: 'busy',
        provider: provider,
        prompt: '排队',
        params: GenerationParams(),
      ),
    );
    await expectLater(
      BackupService(b).prepareImport(zip),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('正在执行或排队'),
        ),
      ),
    );
    expect(await b.db.query('assets'), isEmpty);
  });

  test('上游 v9 任务、输入蒙版标注与明文密钥安全导入并可重复跳过', () async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final input = pngBytes(21);
    final mask = pngBytes(22);
    final markup = pngBytes(23);
    final output = pngBytes(24);
    final manifest = <String, dynamic>{
      'version': 9,
      'exportedAt': DateTime.fromMillisecondsSinceEpoch(now)
          .toUtc()
          .toIso8601String(),
      'settings': {
        'baseUrl': 'https://up.example/v1',
        'model': 'gpt-image-1',
        'apiKey': 'sk-up',
      },
      'providers': [
        {
          'id': 'up',
          'name': '上游',
          'baseUrl': 'https://up.example/v1',
          'apiKey': 'sk-up',
          'model': 'gpt-image-1',
        },
      ],
      'categories': [
        {'id': 'uc', 'name': '上游分类', 'createdAt': now},
      ],
      'promptLibrary': [
        {
          'id': 'upr',
          'title': '上游标题',
          'content': '上游内容',
          'createdAt': now,
          'updatedAt': now,
        },
      ],
      'tasks': [
        {
          'id': 'ut1',
          'prompt': '上游猫',
          'params': {
            'size': '1024x1024',
            'n': 2,
            'output_format': 'webp',
            'output_compression': 80,
            'quality': 'high',
            'moderation': 'auto',
            'background': 'auto',
          },
          'inputImageIds': ['img-in'],
          'editMaskImageId': 'img-mask',
          'editMarkupImageId': 'img-markup',
          'outputImages': ['img-out'],
          'providerId': 'up',
          'categoryId': 'uc',
          'status': 'done',
          'createdAt': now,
          'finishedAt': now + 1000,
          'isFavorite': true,
          'responseMeta': {'requestId': 'r'},
          'editSelection': {'x': 0.1, 'y': 0.2, 'width': 0.3, 'height': 0.4},
        },
      ],
      'imageFiles': {
        'img-in': {
          'path': 'images/in.png',
          'mimeType': 'image/png',
          'createdAt': now,
          'source': 'upload',
        },
        'img-mask': {
          'path': 'images/mask.png',
          'mimeType': 'image/png',
          'createdAt': now,
          'source': 'upload',
        },
        'img-markup': {
          'path': 'images/markup.png',
          'mimeType': 'image/png',
          'createdAt': now,
          'source': 'upload',
        },
        'img-out': {
          'path': 'images/out.png',
          'mimeType': 'image/png',
          'createdAt': now,
          'source': 'generated',
        },
      },
    };
    final zip = zipWith(manifest, {
      'images/in.png': input,
      'images/mask.png': mask,
      'images/markup.png': markup,
      'images/out.png': output,
    });

    final result = await BackupService(b).importBackup(zip);
    expect(result.preview.tasks, 1);
    expect(result.preview.providersAdded, 1);
    final task = (await b.tasks()).single;
    expect(task.input.prompt, '上游猫');
    expect(task.input.params.count, 2);
    expect(task.input.params.format, 'webp');
    expect(task.input.params.compression, 80);
    expect(task.input.references, hasLength(1));
    expect(task.input.mask, isNotNull);
    expect(task.input.markup, isNotNull);
    expect(task.outputs, hasLength(1));
    expect(task.favorite, isTrue);
    final category = (await b.categories()).single;
    expect(task.categoryId, category['id']);
    expect(category['name'], '上游分类');
    expect((await b.prompts()).single['content'], '上游内容');
    final importedProvider = (await b.providers()).single;
    expect(importedProvider.id, 'up');
    expect(importedProvider.baseUrl, 'https://up.example/v1');
    expect(await b.apiKey('up'), 'sk-up');
    expect(await b.db.query('providers'), hasLength(1));
    final localManifest = manifestOf(
      (await BackupService(b).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true))).bytes,
    );
    expect((localManifest['credentials'] as Map)['provider:up'], 'sk-up');
    expect(await b.db.query('assets'), hasLength(4));
    final metadata = jsonDecode(
      (await b.db.query('attempts')).single['metadata'] as String,
    ) as Map<String, dynamic>;
    expect(metadata['source'], 'upstream');
    expect(metadata['editSelection'], isNotNull);

    final again = await BackupService(b).importBackup(zip);
    expect(again.preview.duplicateTasks, 1);
    expect(again.preview.tasks, 0);
    expect(await b.tasks(), hasLength(1));
  });

  test('上游 v6 运行中任务恢复为中断并保留输出', () async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final output = pngBytes(31);
    final manifest = <String, dynamic>{
      'version': 6,
      'settings': {'baseUrl': 'https://v6.example/v1', 'model': 'gpt-image-1'},
      'tasks': [
        {
          'id': 'v6t1',
          'prompt': 'v6 任务',
          'params': const GenerationParams().toJson(),
          'inputImageIds': <String>[],
          'outputImages': ['img-o'],
          'status': 'running',
          'createdAt': now,
        },
      ],
      'imageFiles': {
        'img-o': {
          'path': 'images/o.png',
          'createdAt': now,
          'source': 'generated',
        },
      },
    };
    final zip = zipWith(manifest, {'images/o.png': output});
    await BackupService(b).importBackup(zip);
    final task = (await b.tasks()).single;
    expect(task.status, TaskStatus.interrupted);
    expect(task.error, contains('任务执行已中断'));
    expect(task.outputs, hasLength(1));
    expect(await b.providers(), hasLength(1));
  });
  test('恢复导入中的会话不会清理预览资产，排队任务导入后需手动重试', () async {
    final zip = await seed(a);
    final manifest = manifestOf(zip);
    (manifest['tasks'] as List).single['status'] = 'queued';
    final service = BackupService(b);
    final session = await service.prepareImport(rezip(zip, manifest));
    await service.recoverInterruptedImports();
    await session.commit();
    expect((await b.tasks()).single.status, TaskStatus.interrupted);
    for (final row in await b.db.query('assets')) {
      final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
      expect(await b.fileFor(asset).exists(), isTrue);
    }
  });

  test('导入重映射真实草稿与编辑引用，保留非密钥 token 用量', () async {
    await seed(a);
    final assetRow = (await a.db.query('assets')).first;
    final asset = ImageAsset.fromJson(decodeObject(assetRow['data'] as String));
    await a.db.delete('settings');
    await a.saveSetting('draft', {
      'prompt': '草稿',
      'providerId': 'p1',
      'references': [asset.toJson()],
      'mask': asset.toJson(),
    });
    await a.saveSetting('selection', {'providerId': 'p1'});
    await a.saveSetting('editor:${asset.id}', {
      'rectangles': [],
      'strokes': [],
    });
    await a.saveSetting('usage', {'input_tokens': 12, 'apiKey': 'private-key'});
    await b.saveProvider(
      const ProviderConfig(
        id: 'p1',
        name: '冲突配置',
        baseUrl: 'https://other.example/v1',
      ),
    );
    final zip = (await BackupService(a, directoryA).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true))).bytes;
    await BackupService(b).importBackup(zip);
    final draft = await b.setting('draft') as Map;
    expect(draft['providerId'], isNot('p1'));
    expect(
      (await b.setting('selection') as Map)['providerId'],
      draft['providerId'],
    );
    final reference = ImageAsset.fromJson(
      Map<String, dynamic>.from((draft['references'] as List).single as Map),
    );
    expect(await b.fileFor(reference).exists(), isTrue);
    expect(await b.setting('editor:${reference.id}'), isNotNull);
    expect(await b.setting('usage'), {
      'input_tokens': 12,
      'apiKey': 'private-key',
    });
  });

  test('导入拒绝恶意 SVG 和符号链接', () async {
    final zip = await seed(a);
    final manifest = manifestOf(zip);
    final archive = Archive()
      ..add(ArchiveFile.symlink('linked', '../../outside'));
    await expectLater(
      BackupService(b).prepareImport(ZipEncoder().encodeBytes(archive)),
      throwsA(isA<BackupException>()),
    );
    final svg = utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
    );
    final asset = (manifest['assets'] as List).first as Map;
    asset['mime'] = 'image/svg+xml';
    // 文件内容替换首先应被哈希或图片校验拒绝，数据库保持为空。
    final source = ZipDecoder().decodeBytes(zip);
    final bad = Archive();
    for (final file in source) {
      bad.add(
        ArchiveFile.bytes(
          file.name,
          file.name == 'manifest.json'
              ? utf8.encode(jsonEncode(manifest))
              : svg,
        ),
      );
    }
    await expectLater(
      BackupService(b).importBackup(ZipEncoder().encodeBytes(bad)),
      throwsA(isA<BackupException>()),
    );
    expect(await b.tasks(), isEmpty);
  });

  test('加密完整备份恢复全部九张表、安全存储、回收站和历史配置', () async {
    await seed(a);
    const date = '2026-11-01T12:00:00.000Z';
    await a.updateTask('t1', {'deleted_at': date, 'error': '历史错误 sk-fixture'});
    await a.db.update('attempts', {
      'error': '尝试错误',
      'metadata': jsonEncode({
        'authorization': 'private-value',
        'input_tokens': 12,
      }),
    });
    await a.db.insert('errors', {
      'id': 'e1',
      'task_id': 't1',
      'message': '完整诊断',
      'created_at': date,
    });
    await a.db.insert('errors', {
      'id': 'e2',
      'task_id': null,
      'message': '',
      'created_at': date,
    });
    await a.saveSetting('draft', {
      'prompt': '未提交草稿',
      'providerId': 'p1',
      'parentTaskId': 't1',
    });
    await a.saveSetting('theme', {'mode': 'dark'});
    await a.saveSetting('custom', {
      'secret': 'arbitrary-value',
      'nested': [1, true, null],
    });
    await a.credentials.write(key: 'opaque-session', value: 'session-secret');
    await a.saveProvider(
      const ProviderConfig(
        id: 'p1',
        name: '更新后的供应商',
        baseUrl: 'https://latest.example/v1',
      ),
      key: 'latest-key',
    );
    const password = 'complete-backup-test';
    final encrypted = await BackupService(
      a,
      directoryA,
    ).exportWebBackup(options: BackupOptions(trash: true, password: password, includeCredentials: true));
    expect(encrypted.fileName, endsWith('.igbackup'));
    expect(isEncryptedBackup(encrypted.bytes), isTrue);
    final expected = manifestOf(await decryptBackup(encrypted.bytes, password))
      ..remove('exportedAt');
    secureValues.clear();
    await b.saveSetting('theme', {'mode': 'light'});
    await b.saveDraft({'prompt': '旧草稿'}, null);
    final staleDraft = await b.readDraft();
    final result = await BackupService(b)
        .importBackup(encrypted.bytes, password: password);
    await b.saveDraft(staleDraft.draft!, staleDraft.revision);
    expect((await b.readDraft()).draft?['prompt'], '未提交草稿');
    expect(result.preview.warnings.join('\n'), contains('安全存储'));
    expect((await b.tasks()).single.deletedAt, isNotNull);
    expect((await b.tasks()).single.input.provider.baseUrl, provider.baseUrl);
    expect((await b.providers()).single.baseUrl, 'https://latest.example/v1');
    expect(await b.apiKey('p1'), 'latest-key');
    expect(await b.credentials.read(key: 'opaque-session'), 'session-secret');
    expect(await b.setting('theme'), {'mode': 'dark'});
    final restored = manifestOf((await BackupService(b).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true))).bytes)
      ..remove('exportedAt');
    expect(restored, expected);
    await b.close();
    b = await openStore(directoryB);
    expect(await b.setting('custom'), {
      'secret': 'arbitrary-value',
      'nested': [1, true, null],
    });
    expect(await b.db.query('errors'), hasLength(2));
  });

  test('缺少密码、密码错误、篡改和不完整加密备份不写入数据或密钥', () async {
    await seed(a);
    final backup = await BackupService(
      a,
      directoryA,
    ).exportWebBackup(options: BackupOptions(trash: true, password: 'backup-test-123'));
    secureValues.clear();
    await b.saveSetting('untouched', {'value': 'local-value'});
    final service = BackupService(b);
    await expectLater(
      service.importBackup(backup.bytes),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      service.importBackup(backup.bytes, password: 'incorrect-key'),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          '密码错误或备份文件已损坏',
        ),
      ),
    );
    final corrupt = Uint8List.fromList(backup.bytes)..[36] ^= 1;
    await expectLater(
      service.importBackup(corrupt, password: 'backup-test-123'),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      service.importBackup(
        backup.bytes.sublist(0, 20),
        password: 'backup-test-123',
      ),
      throwsA(isA<BackupException>()),
    );
    expect(await b.tasks(), isEmpty);
    expect(await b.providers(), isEmpty);
    expect(await b.db.query('assets'), isEmpty);
    expect(await b.setting('untouched'), {'value': 'local-value'});
    expect(secureValues, isEmpty);
    expect(await Directory('${b.root.path}/assets').exists(), isFalse);
  });

  test('旧 v1 ZIP 仍可导入，保留旧脱敏和不覆盖设置规则', () async {
    final original = await seed(a);
    final manifest = manifestOf(original)..['version'] = 1;
    manifest.remove('credentials');
    manifest.remove('errors');
    manifest['containsApiKeys'] = false;
    manifest['settings'] = {
      'draft.params': {'size': '1024x1024', 'apiKey': 'must-strip'},
      'theme': {'mode': 'dark'},
    };
    secureValues.clear();
    await b.saveSetting('theme', {'mode': 'light'});
    await BackupService(b).importBackup(rezip(original, manifest));
    expect(await b.tasks(), hasLength(1));
    expect(await b.apiKey('p1'), isNull);
    expect(await b.setting('theme'), {'mode': 'light'});
    expect(await b.setting('draft'), {
      'params': {'size': '1024x1024'},
    });
    expect(await b.db.query('errors'), isEmpty);
  });

  test('完整导入重映射密钥、错误与草稿来源，保留本地记录', () async {
    await seed(a);
    const date = '2026-11-01T12:00:00.000Z';
    await a.db.insert('errors', {
      'id': 'e1',
      'task_id': 't1',
      'message': '待迁移错误',
      'created_at': date,
    });
    await a.saveSetting('draft', {'providerId': 'p1', 'parentTaskId': 't1'});
    final bytes = (await BackupService(a, directoryA).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true))).bytes;
    secureValues.clear();
    const other = ProviderConfig(
      id: 'p1',
      name: '本地供应商',
      baseUrl: 'https://other.example/v1',
    );
    await b.saveProvider(other, key: 'local-key');
    await b.enqueue(
      const GenerationInput(
        taskId: 't1',
        provider: other,
        prompt: '本地任务',
        params: GenerationParams(),
      ),
    );
    await b.updateTask('t1', {'status': 'done'});
    await b.db.insert('errors', {
      'id': 'e1',
      'task_id': 't1',
      'message': '本地错误',
      'created_at': date,
    });
    await BackupService(b).importBackup(bytes);
    final imported = (await b.tasks()).firstWhere(
      (task) => task.input.prompt == '一只猫',
    );
    expect(imported.id, isNot('t1'));
    expect(imported.input.provider.id, isNot('p1'));
    expect(await b.apiKey('p1'), 'local-key');
    expect(await b.apiKey(imported.input.provider.id), 'sk-secret');
    final error = (await b.db.query('errors'))
        .firstWhere((row) => row['message'] == '待迁移错误');
    expect(error['task_id'], imported.id);
    expect(await b.setting('draft'), {
      'providerId': imported.input.provider.id,
      'parentTaskId': imported.id,
    });
    expect(await b.db.query('errors'), hasLength(2));
  });

  test('取消导入预览不恢复密钥、设置或图片', () async {
    final bytes = await seed(a);
    secureValues.clear();
    final plan = await BackupService(b).prepareImport(bytes);
    expect(secureValues, isEmpty);
    expect(await b.tasks(), isEmpty);
    await plan.dispose();
    expect(await b.db.query('assets'), isEmpty);
    expect(await b.db.query('settings'), isEmpty);
    expect(secureValues, isEmpty);
  });

  test('密钥读取失败、活动任务或缺失图片拒绝不完整导出', () async {
    await seed(a);
    readFailure = true;
    await expectLater(
      BackupService(a).exportWebBackup(options: BackupOptions(trash: true, includeCredentials: true)),
      throwsA(isA<PlatformException>()),
    );
    readFailure = false;
    await a.updateTask('t1', {'status': 'queued'});
    await expectLater(
      BackupService(a).exportWebBackup(options: BackupOptions(trash: true)),
      throwsA(isA<BackupException>()),
    );
    await a.updateTask('t1', {'status': 'done'});
    final row = (await a.db.query('assets')).first;
    final asset = ImageAsset.fromJson(decodeObject(row['data'] as String));
    await a.fileFor(asset).delete();
    await expectLater(
      BackupService(a).exportWebBackup(options: BackupOptions(trash: true)),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('缺失'),
        ),
      ),
    );
  });

  test('安全存储写入失败明确警告，保留任务并允许重新导入补全密钥', () async {
    final bytes = await seed(a);
    secureValues.clear();
    writeFailure = true;
    final first = await BackupService(b).importBackup(bytes);
    expect(first.preview.warnings.join('\n'), contains('密钥未能写入'));
    expect(await b.tasks(), hasLength(1));
    expect(await b.apiKey('p1'), isNull);
    writeFailure = false;
    final retry = await BackupService(b).importBackup(bytes);
    expect(retry.preview.tasks, 0);
    expect(await b.apiKey('p1'), 'sk-secret');
  });
}
