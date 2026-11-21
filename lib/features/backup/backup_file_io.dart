import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_service.dart';

/// Returns a status message, or null if the user canceled.
Future<String?> saveBackupFiles(List<File> files, {Rect? shareOrigin}) async {
  if (files.isEmpty) throw const BackupException('没有可保存的备份文件');
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      await const MethodChannel('image_gen/media').invokeMethod<void>(
        'saveBackupToDownloads',
        {'paths': files.map((file) => file.path).toList()},
      );
      return '已保存 ${files.length} 个备份文件到 下载/image-gen-backup。';
    case TargetPlatform.iOS:
      if (shareOrigin == null || shareOrigin.isEmpty || !shareOrigin.isFinite) {
        throw const BackupException('无法定位系统分享面板，请重试');
      }
      // file_picker 的 iOS 保存接口只接受 Uint8List；传文件 URL 避免读取整包。
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [for (final file in files) XFile(file.path)],
          sharePositionOrigin: shareOrigin,
        ),
      );
      return switch (result.status) {
        ShareResultStatus.dismissed => null,
        ShareResultStatus.success => '已完成系统导出，请在所选位置或应用中确认备份文件。',
        ShareResultStatus.unavailable => '系统未确认导出结果，请检查所选位置。',
      };
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      final path = await FilePicker.getDirectoryPath(dialogTitle: '选择备份保存目录');
      if (path == null) return null;
      await copyBackupFiles(files, Directory(path));
      return '已保存 ${files.length} 个备份文件到所选目录。';
    case TargetPlatform.fuchsia:
      throw const BackupException('此平台不支持备份文件导出');
  }
}

@visibleForTesting
Future<void> copyBackupFiles(List<File> files, Directory directory) async {
  final created = <File>[];
  try {
    for (final source in files) {
      final name = source.uri.pathSegments.last;
      final target = File.fromUri(
        directory.absolute.uri.resolveUri(Uri(pathSegments: [name])),
      );
      // 独占创建，遇到同名文件或符号链接时不覆盖原有内容。
      await target.create(exclusive: true);
      created.add(target);
      final output = await target.open(mode: FileMode.write);
      try {
        await for (final chunk in source.openRead()) {
          await output.writeFrom(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
    }
  } on FileSystemException {
    for (final target in created.reversed) {
      try {
        await target.delete();
      } on FileSystemException {
        // 可能已无法访问所选目录，仍继续尝试清理其他分包。
      }
    }
    throw const BackupException('无法写入备份，请检查所选目录权限、空间和同名文件');
  }
}
