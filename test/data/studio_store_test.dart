import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  sqfliteFfiInit();
  late Directory directory;
  late StudioStore store;
  const provider = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://example.com/v1', models: ['gpt-image-1', 'custom-model']);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-gen-test-');
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('供应商配置持久化且快照没有凭据字段', () async {
    await store.saveProvider(provider);
    await store.close();
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    expect((await store.providers()).single.baseUrl, provider.baseUrl);
    expect((await store.providers()).single.enabledModels, provider.enabledModels);
    expect(provider.toJson().keys.any((k) => k.toLowerCase().contains('key')), isFalse);
    expect(const ProviderConfig(id: 'x', name: 'x', baseUrl: 'http://localhost/v1').validate(), isNotNull);
  });

  test('密钥已写而配置仍是旧地址时，不返回新密钥', () async {
    await store.saveProvider(provider, key: 'old-key');
    const next = ProviderConfig(id: 'p', name: '新服务', baseUrl: 'https://next.example/v1');
    await store.credentials.write(key: 'provider:p', value: StudioStore.bindProviderKey(next.baseUrl, 'new-key'));
    expect(await store.apiKey('p', baseUrl: provider.baseUrl), isNull);
    expect(await store.apiKey('p', baseUrl: next.baseUrl), isNull);
    await store.saveProvider(next, key: 'new-key');
    expect(await store.apiKey('p', baseUrl: next.baseUrl), 'new-key');
    expect(await store.apiKey('p', baseUrl: provider.baseUrl), isNull);
  });
  test('落盘去重与中断恢复保留已有输出', () async {
    final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='));
    final asset = await store.saveAsset(png, 'image/png');
    expect((await store.saveAsset(png, 'image/png')).id, asset.id);
    expect(await store.fileFor(asset).readAsBytes(), png);
    await store.enqueue(const GenerationInput(taskId: 't', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('t', {'status': TaskStatus.running.name});
    await store.attachOutput('t', asset, 1, 0);
    // 模拟升级前的 v1 关联表及版本号。
    await store.db.transaction((tx) async {
      await tx.execute('ALTER TABLE task_assets RENAME TO task_assets_v2');
      await tx.execute('CREATE TABLE task_assets(task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, asset_id TEXT NOT NULL REFERENCES assets(id), role TEXT NOT NULL, position INTEGER NOT NULL, attempt INTEGER NOT NULL, PRIMARY KEY(task_id,asset_id,role,attempt))');
      await tx.execute('INSERT INTO task_assets SELECT * FROM task_assets_v2');
      await tx.execute('DROP TABLE task_assets_v2');
      await tx.execute('PRAGMA user_version = 1');
    });
    await store.close();
    store = await StudioStore.open(factory: databaseFactoryFfi, directory: directory);
    expect((await store.task('t'))!.outputs.single.id, asset.id);
    await store.attachOutput('t', asset, 1, 1);
    await store.recoverInterrupted();
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.interrupted);
    expect(task.outputs.map((output) => output.id), [asset.id, asset.id]);
    expect(await store.db.query('assets'), hasLength(1));
  });

  test('缺失输入资产回滚任务，不允许路径逃逸', () async {
    const fake = ImageAsset(id: 'fake', path: '../secret', mime: 'image/png', hash: 'fake', bytes: 1);
    expect(() => store.fileFor(fake), throwsFormatException);
    await expectLater(store.enqueue(const GenerationInput(taskId: 'bad', provider: provider, prompt: '', params: GenerationParams(), references: [fake])), throwsA(isA<DatabaseException>()));
    expect(await store.tasks(), isEmpty);
  });
  test('取消后的迟到输出不可附加，重试保留旧结果', () async {
    final asset = await store.saveAsset(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=='), 'image/png');
    await store.enqueue(const GenerationInput(taskId: 'cancelled', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('cancelled', {'status': 'running', 'attempt': 1});
    expect(await store.attachOutput('cancelled', asset, 1, 0, requireRunning: true), isTrue);
    await store.transition('cancelled', TaskStatus.running, TaskStatus.aborted);
    expect(await store.attachOutput('cancelled', asset, 1, 1, requireRunning: true), isFalse);
    expect(await store.transition('cancelled', TaskStatus.running, TaskStatus.done), isFalse);
    await store.retryTask('cancelled');
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.queued);
    expect(task.outputs, hasLength(1));
    await expectLater(store.retryTask('cancelled'), throwsStateError);
  });

  test('删除分类清除关联，永久删除只允许已停止的回收站任务', () async {
    await store.saveCategory('c', '分类');
    await store.savePrompt('p', '提示', '画一只猫');
    expect((await store.prompts()).single['content'], '画一只猫');
    await store.enqueue(const GenerationInput(taskId: 't', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('t', {'category_id': 'c'});
    await store.deleteCategory('c');
    expect((await store.tasks()).single.categoryId, isNull);
    await expectLater(store.purgeTask('t'), throwsStateError);
    await store.updateTask('t', {'status': 'done'});
    await store.updateTask('t', {'deleted_at': DateTime.now().toUtc().toIso8601String()});
    await store.saveSetting('pending:t:1:0', {'taskId': 't'});
    await store.enqueue(const GenerationInput(taskId: 'expired', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('expired', {'status': 'done'});
    await store.updateTask('expired', {'deleted_at': '2020-01-01T00:00:00Z'});
    await store.saveSetting('pending:expired:1:0', {'taskId': 'expired'});
    await store.purgeTask('t');
    expect(await store.setting('pending:t:1:0'), isNull);
    expect(await store.setting('pending:expired:1:0'), isNotNull);
    await store.pruneExpired();
    expect(await store.setting('pending:expired:1:0'), isNull);
    expect(await store.tasks(), isEmpty);
    await store.deletePrompt('p');
    expect(await store.prompts(), isEmpty);
  });

  test('导入单图直接完成并在清理后保留引用', () async {
    final asset = await store.saveAsset(await solidPng(const ui.Color(0xFF00FF00)), 'image/png');
    await store.importAsset(asset, provider);
    final task = (await store.tasks()).single;
    expect(task.status, TaskStatus.done);
    expect(task.outputs.single.id, asset.id);
    expect((await store.db.query('task_assets', where: 'task_id = ?', whereArgs: [task.id])).single['role'], 'output');
    expect(await store.fileFor(asset).exists(), isTrue);
    await store.pruneOrphanAssets();
    expect(await store.db.query('assets'), hasLength(1));
    expect(await store.fileFor(asset).exists(), isTrue);
  });

  test('老孤立资产被清理，草稿与任务输入引用保留，新鲜孤立资产保留', () async {
    final orphan = await store.saveAsset(await solidPng(const ui.Color(0xFFFF0000)), 'image/png');
    final draft = await store.saveAsset(await solidPng(const ui.Color(0xFF0000FF)), 'image/png');
    final reference = await store.saveAsset(await solidPng(const ui.Color(0xFF000000), width: 4, height: 4), 'image/png');
    final fresh = await store.saveAsset(await solidPng(const ui.Color(0xFFFFFFFF), width: 5, height: 3), 'image/png');
    await store.saveSetting('composition', {'layers': [{'image': draft.toJson()}]});
    await store.db.insert('tasks', {
      'id': 'draft',
      'input': jsonEncode(GenerationInput(taskId: 'draft', provider: provider, prompt: '猫', params: GenerationParams(), references: [reference]).toJson()),
      'status': TaskStatus.done.name,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    final old = DateTime.now().subtract(const Duration(hours: 25));
    for (final asset in [orphan, draft, reference]) {
      await store.fileFor(asset).setLastModified(old);
    }
    await store.pruneOrphanAssets();
    expect((await store.db.query('assets')).map((r) => r['id']).toSet(), {draft.id, reference.id, fresh.id});
    expect(await store.fileFor(orphan).exists(), isFalse);
    expect(await store.fileFor(draft).exists(), isTrue);
    expect(await store.fileFor(reference).exists(), isTrue);
  });

  test('活跃任务阻止孤立资产清理', () async {
    final orphan = await store.saveAsset(await solidPng(const ui.Color(0xFF00FF00), width: 4, height: 2), 'image/png');
    await store.fileFor(orphan).setLastModified(DateTime.now().subtract(const Duration(hours: 25)));
    await store.enqueue(const GenerationInput(taskId: 'queued', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.pruneOrphanAssets();
    expect(await store.db.query('assets', where: 'id = ?', whereArgs: [orphan.id]), hasLength(1));
    expect(await store.fileFor(orphan).exists(), isTrue);
  });

  test('执行中的任务拒绝软删除且不可被彻底删除', () async {
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    await store.enqueue(const GenerationInput(taskId: 'running', provider: provider, prompt: '猫', params: GenerationParams()));
    await store.updateTask('running', {'status': TaskStatus.running.name});
    await expectLater(store.updateTask('running', {'deleted_at': deletedAt}), throwsStateError);
    await store.enqueue(const GenerationInput(taskId: 'queued', provider: provider, prompt: '猫', params: GenerationParams()));
    await expectLater(store.updateTask('queued', {'deleted_at': deletedAt}), throwsStateError);
    expect((await store.tasks()).where((t) => t.deletedAt != null), isEmpty);
    await store.db.update('tasks', {'deleted_at': deletedAt}, where: 'id = ?', whereArgs: ['running']);
    await expectLater(store.purgeTask('running'), throwsStateError);
    expect((await store.tasks()).map((t) => t.id), contains('running'));
  });
  test('批量读取按任务分组并保持尝试和位置顺序，队列不加载历史输出', () async {
    final red = await store.saveAsset(await solidPng(const ui.Color(0xFFFF0000)), 'image/png');
    final blue = await store.saveAsset(await solidPng(const ui.Color(0xFF0000FF)), 'image/png');
    for (final id in ['a', 'b', 'queued']) {
      await store.enqueue(GenerationInput(taskId: id, provider: provider, prompt: id, params: const GenerationParams()));
    }
    await store.updateTask('a', {'status': 'done'});
    await store.updateTask('b', {'status': 'done'});
    await store.attachOutput('a', red, 2, 0);
    await store.attachOutput('a', blue, 1, 1);
    await store.attachOutput('b', red, 0, 0);
    final tasks = {for (final task in await store.tasks()) task.id: task};
    expect(tasks['a']!.outputs.map((a) => a.id), [blue.id, red.id]);
    expect(tasks['b']!.outputs.map((a) => a.id), [red.id]);
    final queued = await store.queuedTasks();
    expect(queued.single.id, 'queued');
    expect(queued.single.outputs, isEmpty);
  });
}

Future<Uint8List> solidPng(ui.Color color, {int width = 3, int height = 2}) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}
