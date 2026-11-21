import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

// v1: magic(8), salt(16), nonce(12), AES-256-GCM ciphertext, tag(16).
final _magic = ascii.encode('IGBACK01');
const _headerLength = 36;
const _maxBackupBytes = 512 * 1024 * 1024;

// v2: magic(8), salt(16), nonce 前缀(8), 块大小(4), 明文总长(8), 块数(8)，
// 随后是每块 AES-256-GCM 密文 + 16 字节 tag。分块加密让大备份不必整包进内存。
final _magicV2 = ascii.encode('IGBACK02');
const _v2HeaderLength = 52;
const _chunkBytes = 1024 * 1024;

bool isEncryptedBackup(List<int> bytes) =>
    _startsWith(bytes, _magic) || _startsWith(bytes, _magicV2);

bool _startsWith(List<int> bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    listEquals(bytes.sublist(0, prefix.length), prefix);

Future<bool> isEncryptedBackupFile(File file) async {
  final handle = await file.open();
  try {
    final head = await handle.read(8);
    return _startsWith(head, _magic) || _startsWith(head, _magicV2);
  } finally {
    await handle.close();
  }
}

Future<Uint8List> encryptBackup(Uint8List bytes, String password) {
  if (password.length < 8 || password.length > 1024) {
    throw const FormatException('备份密码须为 8～1024 个字符');
  }
  if (bytes.length > _maxBackupBytes)
    throw const FormatException('备份超过 512 MB');
  return compute(_encrypt, (bytes, password));
}

Future<Uint8List> decryptBackup(Uint8List bytes, String password) {
  if (bytes.length < _headerLength + 16 ||
      bytes.length > _maxBackupBytes + _headerLength + 16) {
    throw const FormatException('加密备份大小无效或文件不完整');
  }
  if (!isEncryptedBackup(bytes)) throw const FormatException('加密备份格式不受支持');
  if (password.isEmpty || password.length > 1024)
    throw const FormatException('请输入备份密码');
  return compute(_decrypt, (bytes, password));
}

Future<SecretKey> _deriveKey(String password, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: 600000,
  bits: 256,
).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

Future<Uint8List> _encrypt((Uint8List, String) input) async {
  final (bytes, password) = input;
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final cipher = AesGcm.with256bits();
  final nonce = cipher.newNonce();
  final header = <int>[..._magic, ...salt, ...nonce];
  final key = await _deriveKey(password, salt);
  final box = await cipher.encrypt(
    bytes,
    secretKey: key,
    nonce: nonce,
    aad: header,
  );
  return Uint8List(header.length + box.cipherText.length + box.mac.bytes.length)
    ..setRange(0, header.length, header)
    ..setRange(
      header.length,
      header.length + box.cipherText.length,
      box.cipherText,
    )
    ..setRange(
      header.length + box.cipherText.length,
      header.length + box.cipherText.length + box.mac.bytes.length,
      box.mac.bytes,
    );
}

Future<Uint8List> _decrypt((Uint8List, String) input) async {
  final (bytes, password) = input;
  if (_startsWith(bytes, _magicV2)) {
    var offset = 0;
    final output = BytesBuilder(copy: false);
    await _decryptV2(bytes.length, password, (length) async {
      final end = min(offset + length, bytes.length);
      final chunk = Uint8List.sublistView(bytes, offset, end);
      offset = end;
      return chunk;
    }, (clear) async => output.add(clear));
    return output.takeBytes();
  }
  final header = Uint8List.sublistView(bytes, 0, _headerLength);
  final key = await _deriveKey(password, header.sublist(8, 24));
  final box = SecretBox(
    Uint8List.sublistView(bytes, _headerLength, bytes.length - 16),
    nonce: header.sublist(24, 36),
    mac: Mac(Uint8List.sublistView(bytes, bytes.length - 16)),
  );
  try {
    return Uint8List.fromList(
      await AesGcm.with256bits().decrypt(box, secretKey: key, aad: header),
    );
  } on SecretBoxAuthenticationError {
    throw const FormatException('密码错误或备份文件已损坏');
  }
}

/// 分块流式加密，大文件不整包进内存。
Future<void> encryptBackupFile(
  File source,
  File target,
  String password, {
  void Function(int completed, int total)? onProgress,
}) async {
  _checkPassword(password);
  final plainLength = await source.length();
  final chunkCount = plainLength == 0
      ? 0
      : (plainLength + _chunkBytes - 1) ~/ _chunkBytes;
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final prefix = List<int>.generate(8, (_) => random.nextInt(256));
  final header = Uint8List(_v2HeaderLength);
  header.setRange(0, 8, _magicV2);
  header.setRange(8, 24, salt);
  header.setRange(24, 32, prefix);
  final view = ByteData.sublistView(header);
  view.setUint32(32, _chunkBytes);
  view.setUint64(36, plainLength);
  view.setUint64(44, chunkCount);
  onProgress?.call(0, chunkCount);
  final key = await _deriveKey(password, salt);
  final cipher = AesGcm.with256bits();
  final input = await source.open();
  final output = await target.open(mode: FileMode.write);
  try {
    await output.writeFrom(header);
    var index = 0;
    while (true) {
      final chunk = await _readFully(input, _chunkBytes);
      if (chunk.isEmpty) break;
      final box = await cipher.encrypt(
        chunk,
        secretKey: key,
        nonce: [...prefix, ..._u32(index)],
        aad: [...header, ..._u32(index)],
      );
      await output.writeFrom(box.cipherText);
      await output.writeFrom(box.mac.bytes);
      index++;
      onProgress?.call(index, chunkCount);
    }
    if (index != chunkCount) throw const FormatException('备份读取不完整，请重试');
    await output.flush();
  } finally {
    await input.close();
    await output.close();
  }
}

/// 流式解密；兼容 v1 整包格式与 v2 分块格式。
Future<void> decryptBackupFile(
  File source,
  File target,
  String password,
) async {
  if (password.isEmpty || password.length > 1024)
    throw const FormatException('请输入备份密码');
  final handle = await source.open();
  try {
    final head = await handle.read(8);
    if (_startsWith(head, _magic)) {
      await handle.close();
      final plain = await decryptBackup(await source.readAsBytes(), password);
      await target.writeAsBytes(plain, flush: true);
      return;
    }
    if (!_startsWith(head, _magicV2)) throw const FormatException('加密备份格式不受支持');
  } finally {
    // v2 继续复用同一 handle；v1 已提前关闭，close 幂等性由 catch 兜底。
    try {
      await handle.close();
    } on Object catch (_) {}
  }
  final input = await source.open();
  final output = await target.open(mode: FileMode.write);
  try {
    await _decryptV2(await source.length(), password, (length) => _readFully(input, length), output.writeFrom);
    await output.flush();
  } finally {
    await input.close();
    await output.close();
  }
}

Future<void> _decryptV2(int sourceLength, String password, Future<Uint8List> Function(int) read, Future<void> Function(List<int>) write) async {
    final header = await read(_v2HeaderLength);
    if (header.length != _v2HeaderLength)
      throw const FormatException('加密备份大小无效或文件不完整');
    final view = ByteData.sublistView(header);
    final chunkSize = view.getUint32(32);
    if (kIsWeb && (view.getUint32(36) != 0 || view.getUint32(44) != 0)) {
      throw const FormatException('加密备份大小无效或文件不完整');
    }
    final plainLength = kIsWeb ? view.getUint32(40) : view.getUint64(36);
    final chunkCount = kIsWeb ? view.getUint32(48) : view.getUint64(44);
    if (plainLength < 0 || plainLength > sourceLength) {
      throw const FormatException('加密备份大小无效或文件不完整');
    }
    if (chunkSize == 0 || chunkSize > 16 * 1024 * 1024) {
      throw const FormatException('加密备份的块大小无效');
    }
    final expectedCount = plainLength == 0
        ? 0
        : (plainLength + chunkSize - 1) ~/ chunkSize;
    if (chunkCount != expectedCount) throw const FormatException('加密备份的块数无效');
    final expectedLength = _v2HeaderLength + plainLength + chunkCount * 16;
    if (sourceLength != expectedLength) {
      throw const FormatException('加密备份文件不完整或包含多余内容');
    }
    final key = await _deriveKey(password, header.sublist(8, 24));
    final prefix = header.sublist(24, 32);
    final cipher = AesGcm.with256bits();
    var remaining = plainLength;
    for (var index = 0; index < chunkCount; index++) {
      final plain = remaining >= chunkSize ? chunkSize : remaining;
      final body = await read(plain + 16);
      if (body.length != plain + 16)
        throw const FormatException('加密备份文件不完整或包含多余内容');
      final box = SecretBox(
        Uint8List.sublistView(body, 0, plain),
        nonce: [...prefix, ..._u32(index)],
        mac: Mac(Uint8List.sublistView(body, plain)),
      );
      try {
        final clear = await cipher.decrypt(
          box,
          secretKey: key,
          aad: [...header, ..._u32(index)],
        );
        await write(clear);
      } on SecretBoxAuthenticationError {
        throw const FormatException('密码错误或备份文件已损坏');
      }
      remaining -= plain;
    }
}

void _checkPassword(String password) {
  if (password.length < 8 || password.length > 1024) {
    throw const FormatException('备份密码须为 8～1024 个字符');
  }
}

List<int> _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

Future<Uint8List> _readFully(RandomAccessFile file, int length) async {
  final out = Uint8List(length);
  var offset = 0;
  while (offset < length) {
    final chunk = await file.read(length - offset);
    if (chunk.isEmpty) break;
    out.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return offset == length ? out : Uint8List.sublistView(out, 0, offset);
}
