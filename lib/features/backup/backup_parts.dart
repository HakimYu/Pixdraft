import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

const backupPartSize = 512 * 1024 * 1024;
const _headerSize = 48;
const _magic = [73, 71, 80, 65, 82, 84, 48, 49]; // IGPART01

class BackupPartInfo {
  const BackupPartInfo({
    required this.setId,
    required this.index,
    required this.count,
    required this.totalLength,
    required this.payloadLength,
  });

  final String setId;
  final int index;
  final int count;
  final int totalLength;
  final int payloadLength;
}

Future<List<File>> splitBackupFile(
  File source,
  Directory directory, {
  int partSize = backupPartSize,
  void Function(int completed, int total)? onProgress,
}) async {
  if (partSize <= _headerSize) throw ArgumentError.value(partSize, 'partSize');
  final payloadLimit = partSize - _headerSize;
  final length = await source.length();
  onProgress?.call(0, length);
  final count = max(1, (length + payloadLimit - 1) ~/ payloadLimit);
  final setId = Uint8List.fromList(
    List<int>.generate(16, (_) => Random.secure().nextInt(256)),
  );
  final input = await source.open();
  final files = <File>[];
  try {
    for (var index = 0; index < count; index++) {
      final remaining = length - index * payloadLimit;
      final payloadLength = min(payloadLimit, remaining);
      final part = File(
        '${directory.path}/${source.uri.pathSegments.last}.${setId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}.part${(index + 1).toString().padLeft(4, '0')}',
      );
      files.add(part);
      final output = await part.open(mode: FileMode.write);
      final header = Uint8List(_headerSize);
      header.setRange(0, 8, _magic);
      header.setRange(8, 24, setId);
      final view = ByteData.sublistView(header);
      view.setUint32(24, index);
      view.setUint32(28, count);
      view.setUint64(32, length);
      view.setUint64(40, payloadLength);
      try {
        await output.writeFrom(header);
        var copied = 0;
        while (copied < payloadLength) {
          final chunk = await input.read(
            min(1024 * 1024, payloadLength - copied),
          );
          if (chunk.isEmpty) throw const FormatException('分包源文件读取不完整');
          await output.writeFrom(chunk);
          copied += chunk.length;
          onProgress?.call(index * payloadLimit + copied, length);
        }
        await output.flush();
      } finally {
        await output.close();
      }
    }
  } catch (_) {
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    rethrow;
  } finally {
    await input.close();
  }
  return files;
}

Future<BackupPartInfo?> readBackupPartInfo(
  File file, {
  int partSize = backupPartSize,
}) async {
  final input = await file.open();
  try {
    final header = await input.read(_headerSize);
    if (header.length < 8 || !listEquals(header.take(8).toList(), _magic))
      return null;
    if (header.length != _headerSize) throw const FormatException('分包头损坏');
    final view = ByteData.sublistView(header);
    final count = view.getUint32(28);
    final index = view.getUint32(24);
    final totalLength = view.getUint64(32);
    final payloadLength = view.getUint64(40);
    if (count == 0 ||
        index >= count ||
        payloadLength > partSize - _headerSize ||
        await file.length() != _headerSize + payloadLength) {
      throw const FormatException('分包长度或编号无效');
    }
    return BackupPartInfo(
      setId: header
          .sublist(8, 24)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      index: index,
      count: count,
      totalLength: totalLength,
      payloadLength: payloadLength,
    );
  } finally {
    await input.close();
  }
}

Future<File> joinBackupParts(
  List<File> parts,
  Directory directory, {
  int partSize = backupPartSize,
}) async {
  if (parts.isEmpty) throw const FormatException('未选择备份分包');
  final parsed = <(File, BackupPartInfo)>[];
  for (final file in parts) {
    final info = await readBackupPartInfo(file, partSize: partSize);
    if (info == null) throw const FormatException('所选文件不是有效备份分包');
    parsed.add((file, info));
  }
  final first = parsed.first.$2;
  if (parsed.length != first.count ||
      parsed.any(
        (entry) =>
            entry.$2.setId != first.setId ||
            entry.$2.count != first.count ||
            entry.$2.totalLength != first.totalLength,
      )) {
    throw const FormatException('备份分包缺失或混入了其他备份');
  }
  parsed.sort((a, b) => a.$2.index.compareTo(b.$2.index));
  for (var i = 0; i < parsed.length; i++) {
    if (parsed[i].$2.index != i) throw const FormatException('备份分包重复或编号缺失');
  }
  final sum = parsed.fold<int>(
    0,
    (value, entry) => value + entry.$2.payloadLength,
  );
  if (sum != first.totalLength) throw const FormatException('备份分包总长度不匹配');
  final outputFile = File('${directory.path}/backup-parts-${first.setId}.bin');
  final output = await outputFile.open(mode: FileMode.write);
  try {
    for (final (file, _) in parsed) {
      final input = await file.open();
      try {
        await input.setPosition(_headerSize);
        var remaining = (await readBackupPartInfo(
          file,
          partSize: partSize,
        ))!.payloadLength;
        while (remaining > 0) {
          final chunk = await input.read(min(1024 * 1024, remaining));
          if (chunk.isEmpty) throw const FormatException('备份分包内容不完整');
          await output.writeFrom(chunk);
          remaining -= chunk.length;
        }
      } finally {
        await input.close();
      }
    }
    await output.flush();
  } catch (_) {
    await output.close();
    if (await outputFile.exists()) await outputFile.delete();
    rethrow;
  }
  await output.close();
  return outputFile;
}
