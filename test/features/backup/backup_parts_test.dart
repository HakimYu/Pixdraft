import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/backup/backup_parts.dart';

void main() {
  test('分包支持乱序合并并拒绝缺片、重复和混包', () async {
    final directory = await Directory.systemTemp.createTemp('backup-parts-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.bin');
    final bytes = List<int>.generate(4096, (i) => i % 251);
    await source.writeAsBytes(bytes);
    final parts = await splitBackupFile(source, directory, partSize: 256);
    expect(parts.length, greaterThan(1));
    expect(parts.every((file) => file.lengthSync() <= 256), isTrue);
    final joined = await joinBackupParts(
      parts.reversed.toList(),
      directory,
      partSize: 256,
    );
    expect(await joined.readAsBytes(), bytes);
    await expectLater(
      joinBackupParts(parts.skip(1).toList(), directory, partSize: 256),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      joinBackupParts([...parts, parts.first], directory, partSize: 256),
      throwsA(isA<FormatException>()),
    );
    final second = await splitBackupFile(source, directory, partSize: 256);
    await expectLater(
      joinBackupParts(
        [parts.first, ...second.skip(1), ...parts.skip(2)],
        directory,
        partSize: 256,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
