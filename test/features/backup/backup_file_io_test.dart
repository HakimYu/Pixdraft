import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/backup/backup_file_io.dart';
import 'package:image_gen/features/backup/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android passes all file paths and propagates native failure', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('image_gen/media');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    final files = [File('one.part0001'), File('two.part0002')];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'saveBackupToDownloads');
      expect(call.arguments, {
        'paths': files.map((file) => file.path).toList(),
      });
      return null;
    });
    expect(await saveBackupFiles(files), contains('已保存 2 个'));
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'storage_permission');
    });
    await expectLater(
      saveBackupFiles(files),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'iPad passes paths and popover origin and reports cancellation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      const origin = Rect.fromLTWH(1, 2, 3, 4);
      final files = [File('one.zip')];
      await expectLater(
        saveBackupFiles(files),
        throwsA(isA<BackupException>()),
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'share');
        expect(call.arguments['paths'], ['one.zip']);
        expect(call.arguments['originWidth'], 3);
        return '';
      });
      expect(await saveBackupFiles(files, shareOrigin: origin), isNull);
    },
  );
  test('desktop rollback preserves an existing file and the sources', () async {
    final root = await Directory.systemTemp.createTemp();
    addTearDown(() => root.delete(recursive: true));
    final source = await Directory('${root.path}/source').create();
    final target = await Directory('${root.path}/target').create();
    final first = await File('${source.path}/one #1.part0001')
        .writeAsString('1');
    final second = await File('${source.path}/one #1.part0002')
        .writeAsString('2');
    final existing = await File('${target.path}/one #1.part0002')
        .writeAsString('keep');
    await expectLater(
      copyBackupFiles([first, second], target),
      throwsA(isA<BackupException>()),
    );
    expect(await target.list().toList(), hasLength(1));
    expect(await existing.readAsString(), 'keep');
    await copyBackupFiles([first], target);
    expect(await File('${target.path}/one #1.part0001').readAsString(), '1');
    expect(await second.readAsString(), '2');
  });
}
