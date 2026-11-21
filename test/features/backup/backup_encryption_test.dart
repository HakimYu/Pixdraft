import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/backup/backup_encryption.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('解密独立 Python cryptography 生成的固定备份，包含中文密码', () async {
    const hex =
        '49474241434b3031000102030405060708090a0b0c0d0e0f101112131415161718191a1b50353f5b0870e3777ebaec91fd73ec31516636a8f11f562e46eb4e64834665b81cae57566a55ac';
    final fixture = Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    expect(
      utf8.decode(await decryptBackup(fixture, 'test-password-中文')),
      'portable backup fixture',
    );
  });

  test('随机盐和 nonce、密码原样使用，头部和密文认证失败', () async {
    final bytes = Uint8List.fromList(utf8.encode('原图和 sk-test-key'));
    const password = '  backup-test-中文  ';
    final first = await encryptBackup(bytes, password);
    final second = await encryptBackup(bytes, password);
    expect(isEncryptedBackup(first), isTrue);
    expect(first, isNot(orderedEquals(second)));
    expect(first.sublist(8, 36), isNot(orderedEquals(second.sublist(8, 36))));
    expect(
      utf8.decode(first, allowMalformed: true),
      isNot(contains('sk-test-key')),
    );
    expect(await decryptBackup(first, password), bytes);
    await expectLater(
      decryptBackup(first, password.trim()),
      throwsA(isA<FormatException>()),
    );
    for (final offset in [8, 24, 36, first.length - 1]) {
      final corrupt = Uint8List.fromList(first)..[offset] ^= 1;
      await expectLater(
        decryptBackup(corrupt, password),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('拒绝短密码、过长密码、不完整或未知格式', () {
    final empty = Uint8List(0);
    expect(() => encryptBackup(empty, 'short'), throwsFormatException);
    expect(() => encryptBackup(empty, 'x' * 1025), throwsFormatException);
    expect(() => decryptBackup(empty, 'backup-test'), throwsFormatException);
    expect(
      () => decryptBackup(Uint8List(60), 'backup-test'),
      throwsFormatException,
    );
    final header = Uint8List(60)..setRange(0, 8, ascii.encode('IGBACK01'));
    expect(() => decryptBackup(header, ''), throwsFormatException);
    expect(() => decryptBackup(header, 'x' * 1025), throwsFormatException);
  });
  test('IGBACK02 文件流分块往返并拒绝截断与重排', () async {
    final dir = await Directory.systemTemp.createTemp('igbackup-v2-');
    addTearDown(() => dir.delete(recursive: true));
    final source = File('${dir.path}/plain.bin');
    final encrypted = File('${dir.path}/encrypted.bin');
    final restored = File('${dir.path}/restored.bin');
    final bytes = Uint8List.fromList(
      List<int>.generate(2 * 1024 * 1024 + 37, (i) => i % 251),
    );
    await source.writeAsBytes(bytes);
    await encryptBackupFile(source, encrypted, 'password-123');
    expect(await isEncryptedBackupFile(encrypted), isTrue);
    await decryptBackupFile(encrypted, restored, 'password-123');
    expect(await restored.readAsBytes(), bytes);
    final corrupt = File('${dir.path}/corrupt.bin');
    final damaged = await encrypted.readAsBytes();
    damaged[52 + 1024 * 1024 + 3] ^= 1;
    await corrupt.writeAsBytes(damaged);
    await expectLater(
      decryptBackupFile(corrupt, File('${dir.path}/bad.bin'), 'password-123'),
      throwsFormatException,
    );
    final truncated = File('${dir.path}/truncated.bin');
    await truncated.writeAsBytes(damaged.sublist(0, damaged.length - 1));
    await expectLater(
      decryptBackupFile(
        truncated,
        File('${dir.path}/short.bin'),
        'password-123',
      ),
      throwsFormatException,
    );
  });
}
