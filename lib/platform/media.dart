import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/studio_store.dart';
import '../models/models.dart';

const fileShareAlternative = '此系统不支持直接分享文件，请先保存图片，再从文件管理器分享。';

bool get supportsFileShare =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// `unavailable` means the system does not report the share outcome.
Future<ShareResultStatus> shareImages(
  StudioStore store,
  Iterable<ImageAsset> assets, {
  Rect? shareOrigin,
}) async {
  if (!supportsFileShare) throw UnsupportedError(fileShareAlternative);
  if (defaultTargetPlatform == TargetPlatform.iOS &&
      (shareOrigin == null || shareOrigin.isEmpty || !shareOrigin.isFinite)) {
    throw StateError('无法定位系统分享面板，请重试');
  }
  try {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final asset in assets)
            XFile(store.fileFor(asset).path, mimeType: asset.mime),
        ],
        sharePositionOrigin: shareOrigin,
      ),
    );
    return result.status;
  } on UnimplementedError {
    throw UnsupportedError(fileShareAlternative);
  }
}

Future<bool> saveImageToDevice(StudioStore store, ImageAsset asset) async {
  PlatformException? galleryError;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android &&
      asset.mime != 'image/svg+xml') {
    try {
      final saved = await const MethodChannel('image_gen/media')
          .invokeMethod<bool>('saveToGallery', {
            'path': store.fileFor(asset).path,
            'mime': asset.mime,
          });
      if (saved == true) return true;
    } on PlatformException catch (error) {
      galleryError = error;
    } on MissingPluginException {
      // 原生通道不可用时仍可用系统文件保存窗口。
    }
  }
  try {
    final saved = await FilePicker.saveFile(
      dialogTitle: '保存图片',
      mimeType: asset.mime,
      fileName: 'image_${asset.id.length > 8 ? asset.id.substring(0, 8) : asset.id}.${asset.path.split('.').last}',
      bytes: await store.readAsset(asset),
    );
    // 浏览器只发起下载，不返回目标路径或写入结果。
    return kIsWeb || saved != null;
  } catch (_) {
    if (galleryError != null) {
      throw PlatformException(
        code: galleryError.code,
        message: '${galleryError.message ?? '无法保存到相册'}；文件另存也失败，可尝试“分享 / 导出”',
      );
    }
    rethrow;
  }
}
