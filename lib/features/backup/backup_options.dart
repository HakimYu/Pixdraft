import 'dart:io';

/// 导出范围与格式选项。默认四类记录全选、回收站/密码/分包都不勾。
class BackupOptions {
  const BackupOptions({
    this.works = true,
    this.providers = true,
    this.includeCredentials = false,
    this.prompts = true,
    this.settings = true,
    this.errors = true,
    this.trash = false,
    this.password,
    this.split = false,
  });

  /// 作品与历史（不含回收站）。
  final bool works;

  /// 供应商与模型配置。
  final bool providers;

  /// 明确选择后才导出凭据；未加密备份中的凭据可被直接读取。
  final bool includeCredentials;
  final bool prompts;

  /// 设置与草稿。
  final bool settings;
  final bool errors;

  /// 回收站里的任务，单独一个开关。
  final bool trash;

  /// 为空表示不加密。
  final String? password;

  /// 每包 512 MiB 的分包导出。
  final bool split;

  bool get isEmpty =>
      !works && !providers && !prompts && !settings && !errors && !trash;

  bool get encrypted => password != null;

  BackupOptions copyWith({
    bool? works,
    bool? providers,
    bool? includeCredentials,
    bool? prompts,
    bool? settings,
    bool? errors,
    bool? trash,
    String? password,
    bool clearPassword = false,
    bool? split,
  }) => BackupOptions(
    works: works ?? this.works,
    providers: providers ?? this.providers,
    includeCredentials: includeCredentials ?? this.includeCredentials,
    prompts: prompts ?? this.prompts,
    settings: settings ?? this.settings,
    errors: errors ?? this.errors,
    trash: trash ?? this.trash,
    password: clearPassword ? null : password ?? this.password,
    split: split ?? this.split,
  );
}

/// 一次导出产出的文件；分包时 [files] 按序号排列，全部都要分享出去。
class BackupPackage {
  const BackupPackage({
    required this.files,
    required this.split,
    required this.encrypted,
    required this.tasks,
    required this.assets,
    required this.attempts,
    required this.providers,
    required this.categories,
    required this.prompts,
    required this.settings,
  });

  final List<File> files;
  final bool split;
  final bool encrypted;
  final int tasks;
  final int assets;
  final int attempts;
  final int providers;
  final int categories;
  final int prompts;
  final int settings;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.lengthSync());
}
