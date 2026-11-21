import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/backup/backup_page.dart';
import 'package:image_gen/features/backup/backup_options.dart';
import 'package:image_gen/features/backup/backup_service.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExportFile implements File {
  _ExportFile(this.path);

  @override
  final String path;
  bool deleted = false;

  @override
  Future<File> delete({bool recursive = false}) async {
    deleted = true;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExportService extends BackupService {
  _ExportService(super.store);

  final result = Completer<List<File>>();
  BackupExportProgress? report;
  BackupOptions? selectedOptions;

  @override
  Future<void> recoverInterruptedImports() async {}

  @override
  Future<List<File>> writeExportFiles({
    required BackupOptions options,
    int partSize = 512 * 1024 * 1024,
    BackupExportProgress? onProgress,
  }) {
    report = onProgress;
    selectedOptions = options;
    return result.future;
  }
}

class _Picker extends FilePickerPlatform {
  FileType? requestedType;
  PlatformFile? file;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requestedType = type;
    return file == null ? [] : [file!];
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requestedType = type;
    return file;
  }
}

void main() {
  testWidgets('导出显示当前阶段和百分比，失败后清除进度', (tester) async {
    final store = StudioStore(_UnusedDatabase(), Directory.systemTemp);
    addTearDown(store.dispose);
    final service = _ExportService(store);
    await tester.pumpWidget(
      MaterialApp(
        home: BackupPage(store: store, service: service),
      ),
    );
    await tester.tap(find.text('导出备份'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.widgetWithText(FilledButton, '导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('正在准备备份'), findsOneWidget);

    service.report!('打包备份', 1, 4);
    await tester.pump();
    expect(find.text('打包备份：25%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.25,
    );

    service.result.completeError(const BackupException('磁盘空间不足'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('磁盘空间不足'), findsWidgets);
  });

  testWidgets('导出将所有分包保存到下载目录并清理缓存', (tester) async {
    final store = StudioStore(_UnusedDatabase(), Directory.systemTemp);
    addTearDown(store.dispose);
    final service = _ExportService(store);
    final files = [
      _ExportFile('/cache/image-gen-backup-test.zip.part0001'),
      _ExportFile('/cache/image-gen-backup-test.zip.part0002'),
    ];
    const channel = MethodChannel('image_gen/media');
    final messenger = tester.binding.defaultBinaryMessenger;
    final saved = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'saveBackupToDownloads');
      expect(call.arguments, {
        'paths': files.map((file) => file.path).toList(),
      });
      return saved.future;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: BackupPage(store: store, service: service),
      ),
    );
    await tester.tap(find.text('导出备份'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.widgetWithText(FilledButton, '导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.selectedOptions?.includeCredentials, isFalse);
    service.result.complete(files);
    await tester.pump();
    expect(find.text('正在保存到下载目录'), findsOneWidget);
    expect(files.every((file) => !file.deleted), isTrue);
    saved.complete();
    await tester.pumpAndSettle();
    expect(find.text('已保存 2 个备份文件到 下载/image-gen-backup。'), findsOneWidget);
    expect(files.every((file) => file.deleted), isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  testWidgets('iPad 传递按钮锚点，明确选中凭据后导出，取消后清理缓存', (tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });
    final store = StudioStore(_UnusedDatabase(), Directory.systemTemp);
    addTearDown(store.dispose);
    final service = _ExportService(store);
    final file = _ExportFile('/cache/image-gen-backup-test.zip');
    final cancellation = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: BackupPage(store: store, service: service),
      ),
    );
    final button = find.widgetWithText(FilledButton, '导出备份');
    final bounds = tester.getRect(button);
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) {
      called = true;
      expect(call.method, 'share');
      expect(call.arguments['paths'], [file.path]);
      expect(call.arguments['originX'], bounds.left);
      expect(call.arguments['originY'], bounds.top);
      expect(call.arguments['originWidth'], bounds.width);
      expect(call.arguments['originHeight'], bounds.height);
      return cancellation.future;
    });
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final credential = find.widgetWithText(CheckboxListTile, '包含 API 密钥等凭据');
    const warning = '未加密的凭据可被任何取得备份文件的人读取。建议用密码加密。';
    expect(tester.widget<CheckboxListTile>(credential).value, isFalse);
    expect(find.text(warning), findsNothing);
    await tester.ensureVisible(credential);
    await tester.tap(credential);
    await tester.pump();
    expect(find.text(warning), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(service.selectedOptions?.includeCredentials, isTrue);
    service.result.complete([file]);
    await tester.pump();
    expect(called, isTrue);
    expect(file.deleted, isFalse);
    cancellation.complete('');
    await tester.pumpAndSettle();
    expect(find.text('已取消导出'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(file.deleted, isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  testWidgets('导入不按 ZIP MIME 过滤，允许选择自定义加密备份，取消无写入', (tester) async {
    final original = FilePickerPlatform.instance;
    final picker = _Picker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);
    final store = StudioStore(_UnusedDatabase(), Directory.systemTemp);
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(home: BackupPage(store: store)));
    await tester.tap(find.text('从备份导入'));
    await tester.pumpAndSettle();
    expect(picker.requestedType, FileType.any);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('导出默认不加密，选择密码后校验长度和确认密码', (tester) async {
    final store = StudioStore(_UnusedDatabase(), Directory.systemTemp);
    addTearDown(store.dispose);
    await tester.pumpWidget(MaterialApp(home: BackupPage(store: store)));
    await tester.tap(find.text('导出备份'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).last).value,
      isFalse,
    );
    await tester.ensureVisible(find.text('用密码加密'));
    await tester.tap(find.text('用密码加密'));
    await tester.pump();
    expect(find.byType(TextFormField), findsNWidgets(2));
    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.obscureText, isTrue);
    }
    await tester.tap(find.widgetWithText(FilledButton, '导出'));
    await tester.pump();
    expect(find.text('请输入备份密码'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'short');
    await tester.enterText(find.byType(TextFormField).last, 'different');
    await tester.tap(find.widgetWithText(FilledButton, '导出'));
    await tester.pump();
    expect(find.text('请使用至少 8 个字符'), findsOneWidget);
    expect(find.text('两次密码不一致'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导出备份'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
}
