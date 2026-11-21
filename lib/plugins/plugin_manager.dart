import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/studio_store.dart';
import 'plugin_manifest.dart';

/// 已安装插件（含内置）的对外视图。
class InstalledPlugin {
  const InstalledPlugin({
    required this.id,
    required this.name,
    required this.version,
    this.enabled = true,
    this.builtIn = false,
    this.versions = const [],
    this.manifest,
  });
  final String id, name, version;
  final bool enabled, builtIn;

  /// 磁盘上保留的全部版本，新的在前；内置为空。
  final List<String> versions;
  final PluginManifest? manifest;

  InstalledPlugin copyWith({bool? enabled, String? version}) => InstalledPlugin(
    id: id,
    name: name,
    version: version ?? this.version,
    enabled: enabled ?? this.enabled,
    builtIn: builtIn,
    versions: versions,
    manifest: manifest,
  );
}

/// 磁盘上某个版本的实际安装；registry 据此构造扩展。
class PluginInstallation {
  const PluginInstallation({
    required this.plugin,
    required this.directory,
    required this.version,
  });
  final InstalledPlugin plugin;
  final Directory directory;
  final String version;
}

/// 插件索引存于 settings，目录仅存解包内容：状态与文件不双写。
const String pluginIndexKey = 'plugins.index.v1';

/// 内容指纹文件名：同版本换包必须拒绝，不能静默覆盖已 pin 任务使用的代码。
const String pluginPackageHashFile = '.package-hash';

/// 校验通过的安装包；落盘前不执行任何脚本。
class _PluginPackage {
  const _PluginPackage({
    required this.manifest,
    required this.files,
    required this.hash,
  });
  final PluginManifest manifest;
  final Map<String, ArchiveFile> files;
  final String hash;
}

/// 安装、启停与卸载；所有失败在切换目录前抛出，旧版本保持可用。
class PluginManager {
  PluginManager(this.store);
  final StudioStore store;

  Directory get _root => Directory(p.join(store.root.path, 'plugins'));

  Directory _versionDir(String id, String version) =>
      Directory(p.join(_root.path, id, version));

  Future<Map<String, Map<String, dynamic>>> _index() async {
    final raw = await store.setting(pluginIndexKey);
    final plugins = raw?['plugins'];
    if (plugins is! Map) return {};
    return {
      for (final entry in plugins.entries)
        entry.key.toString(): Map<String, dynamic>.from(entry.value as Map),
    };
  }

  Future<void> _writeIndex(Map<String, Map<String, dynamic>> index) =>
      store.saveSetting(pluginIndexKey, {'plugins': index});

  /// 内置插件：版本固定，不落盘。
  static const List<InstalledPlugin> builtinPlugins = [
    InstalledPlugin(
      id: 'builtin.providers',
      name: '内置生图适配器',
      version: builtinPluginVersion,
      builtIn: true,
    ),
    InstalledPlugin(
      id: 'builtin.local-tools',
      name: '内置本地处理',
      version: builtinPluginVersion,
      builtIn: true,
    ),
  ];

  /// 内置 + 已安装的动态插件；内置随宿主始终存在，禁用状态由索引覆盖。
  Future<List<InstalledPlugin>> list() async {
    final index = await _index();
    final plugins = <InstalledPlugin>[
      for (final plugin in builtinPlugins)
        plugin.copyWith(enabled: index[plugin.id]?['enabled'] as bool? ?? true),
    ];
    if (kIsWeb) return plugins;
    for (final entry in index.entries) {
      if (builtinPluginIds.contains(entry.key)) continue;
      plugins.addAll(await _installedFrom(entry.key, entry.value));
    }
    return plugins;
  }

  Future<List<InstalledPlugin>> _installedFrom(
    String id,
    Map<String, dynamic> state,
  ) async {
    final versions = await _versionsOf(id);
    if (versions.isEmpty) return const [];
    final active = versions.first;
    final manifest = await _manifestAt(id, active);
    return [
      InstalledPlugin(
        id: id,
        name: manifest?.name ?? state['name'] as String? ?? id,
        version: active,
        enabled: state['enabled'] as bool? ?? false,
        versions: versions,
        manifest: manifest,
      ),
    ];
  }

  /// 版本按数字降序。
  Future<List<String>> _versionsOf(String id) async {
    final dir = Directory(p.join(_root.path, id));
    if (!await dir.exists()) return const [];
    final versions = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (_looksLikeVersion(name) &&
          await File(p.join(entity.path, 'plugin.json')).exists()) {
        versions.add(name);
      }
    }
    final parsed = versions;
    parsed.sort((a, b) {
      final left = a.split('.').map(int.parse).toList(),
          right = b.split('.').map(int.parse).toList();
      for (var i = 0; i < 3; i++) {
        final diff = right[i].compareTo(left[i]);
        if (diff != 0) return diff;
      }
      return 0;
    });
    return parsed;
  }

  static bool _looksLikeVersion(String name) =>
      RegExp(r'^\d{1,6}\.\d{1,6}\.\d{1,6}$').hasMatch(name);

  Future<PluginManifest?> _manifestAt(String id, String version) async {
    final file = File(p.join(_versionDir(id, version).path, 'plugin.json'));
    if (!await file.exists()) return null;
    try {
      return PluginManifest.fromJson(
        Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } on Object {
      return null;
    }
  }

  /// 只读检查安装包：完整静态校验，不落盘、不执行脚本。
  Future<PluginManifest> inspect(Uint8List bytes) async =>
      (await _validate(bytes)).manifest;

  /// 安装包：校验包体、清单与路径后才落盘，失败不破坏已装版本；新装默认不启用。
  Future<InstalledPlugin> install(Uint8List bytes) async {
    final package = await _validate(bytes);
    final manifest = package.manifest;
    final target = _versionDir(manifest.id, manifest.version);
    final previousHash = await _readHash(target);
    if (previousHash != null && previousHash != package.hash) {
      throw PluginException(
        '插件 ${manifest.id} 已安装版本 ${manifest.version} 的不同内容，请提升版本号后重装',
      );
    }

    final temporary = Directory(
      p.join(
        _root.path,
        manifest.id,
        '.incoming-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temporary.create(recursive: true);
    try {
      for (final entry in package.files.entries) {
        final file = File(p.join(temporary.path, entry.key));
        if (!p.isWithin(temporary.path, file.path)) {
          throw PluginException('插件包路径逃逸：${entry.key}');
        }
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value.content, flush: true);
      }
      await File(p.join(temporary.path, pluginPackageHashFile))
          .writeAsString(package.hash, flush: true);
      await temporary.rename(target.path);
    } on FileSystemException catch (error) {
      // 同版本重装：先备份旧目录，成功后才丢弃备份。
      if (!await target.exists() || !await temporary.exists()) {
        await _deleteQuietly(temporary);
        throw PluginException('写入插件目录失败：${error.message}');
      }
      final backup = Directory(
        p.join(
          _root.path,
          manifest.id,
          '.previous-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } on Object {
        await backup.rename(target.path);
        await _deleteQuietly(temporary);
        rethrow;
      }
      await _deleteQuietly(backup);
    }

    final index = await _index();
    final state = index[manifest.id];
    // 初装不启用：用户确认代码执行与授权域名后才允许运行。
    index[manifest.id] = {
      'name': manifest.name,
      'enabled': state?['enabled'] as bool? ?? false,
    };
    await _writeIndex(index);
    return (await _installedFrom(manifest.id, index[manifest.id]!)).first;
  }

  Future<String?> _readHash(Directory dir) async {
    final file = File(p.join(dir.path, pluginPackageHashFile));
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  }

  /// 只读中央目录（archive 的 ZipDirectory），不触碰条目数据。
  ///
  /// archive 的 Archive.add 对同名条目「后者覆盖前者」，且符号链接会在解码时
  /// 提前展开 target，所以这些约束必须在 decodeBytes 之前基于原始头判断。
  void _checkCentralDirectory(Uint8List bytes) {
    final directory = ZipDirectory();
    final headers = directory
        .headers(InputMemoryStream(bytes), files: false)
        .toList(growable: false);
    if (directory.filePosition < 0) {
      throw const PluginException('不是有效的 Zip 包：缺少中央目录');
    }
    final names = <String>{};
    var declared = 0;
    for (final header in headers) {
      final name = header.filename;
      final unixMode = header.versionMadeBy >> 8 == 3
          ? header.externalFileAttributes >> 16
          : 0;
      if (unixMode & 0xf000 == 0xa000) {
        throw PluginException('插件包不允许符号链接：$name');
      }
      if (name.endsWith('/') || name.endsWith('\\')) continue;
      if (!names.add(name)) throw PluginException('插件包内路径重复：$name');
      _checkEntryPath(name);
      if (names.length > pluginMaxFiles) {
        throw PluginException('插件包文件数超过 $pluginMaxFiles');
      }
      declared += header.uncompressedSize;
      if (declared > pluginMaxUnpackedBytes) {
        throw PluginException(
          '解压后超过 ${pluginMaxUnpackedBytes ~/ (1024 * 1024)} MiB',
        );
      }
    }
  }

  Future<_PluginPackage> _validate(Uint8List bytes) async {
    if (bytes.isEmpty) throw const PluginException('插件包为空');
    if (bytes.length > pluginMaxPackageBytes) {
      throw PluginException(
        '插件包超过 ${pluginMaxPackageBytes ~/ (1024 * 1024)} MiB',
      );
    }
    // 先只读中央目录：重复名、符号链接、超量与逃逸必须在解码器展开任何条目之前拒绝。
    _checkCentralDirectory(bytes);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } on Object catch (error) {
      throw PluginException('不是有效的 Zip 包：$error');
    }

    final files = <String, ArchiveFile>{};
    var unpacked = 0;
    for (final file in archive) {
      final name = file.name;
      if (file.isSymbolicLink) throw PluginException('插件包不允许符号链接：$name');
      if (!file.isFile) continue;
      _checkEntryPath(name);
      if (files.containsKey(name)) throw PluginException('插件包内路径重复：$name');
      unpacked += file.size;
      if (files.length >= pluginMaxFiles) {
        throw PluginException('插件包文件数超过 $pluginMaxFiles');
      }
      if (unpacked > pluginMaxUnpackedBytes) {
        throw PluginException(
          '解压后超过 ${pluginMaxUnpackedBytes ~/ (1024 * 1024)} MiB',
        );
      }
      files[name] = file;
    }

    final manifestFile = files['plugin.json'];
    if (manifestFile == null) {
      throw const PluginException('插件包根目录缺少 plugin.json');
    }
    final PluginManifest manifest;
    try {
      manifest = PluginManifest.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(utf8.decode(manifestFile.content)) as Map,
        ),
      );
    } on PluginException {
      rethrow;
    } on Object catch (error) {
      throw PluginException('plugin.json 解析失败：$error');
    }
    final entry = files[manifest.entry];
    if (entry == null) throw PluginException('入口文件 ${manifest.entry} 不在包内');
    if (entry.size > pluginMaxEntryBytes) {
      throw PluginException(
        '入口文件超过 ${pluginMaxEntryBytes ~/ (1024 * 1024)} MiB',
      );
    }
    try {
      utf8.decode(entry.content);
    } on Object {
      throw const PluginException('入口脚本需为 UTF-8 文本');
    }
    await _rejectExtensionCollisions(manifest);
    return _PluginPackage(
      manifest: manifest,
      files: files,
      hash: sha256.convert(bytes).toString(),
    );
  }

  /// 同一扩展 ID 只能属于一个插件：不同插件不能靠版本号接管别人的扩展，
  /// 包括禁用/卸载后仍保留在磁盘上供 pin 任务使用的旧版本。
  Future<void> _rejectExtensionCollisions(PluginManifest manifest) async {
    final incoming = _extensionIds(manifest);
    if (incoming.isEmpty) return;
    for (final installation in await allInstallations()) {
      final other = installation.plugin.manifest;
      if (other == null || other.id == manifest.id) continue;
      final conflict = _extensionIds(other).intersection(incoming).firstOrNull;
      if (conflict == null) continue;
      throw PluginException(
        '插件 ${manifest.id} 的扩展「$conflict」已属于插件 ${other.id}，同一扩展 ID 只能由一个插件声明',
      );
    }
  }

  static Set<String> _extensionIds(PluginManifest manifest) => {
    for (final spec in manifest.providers) spec.id,
    for (final spec in manifest.processors) spec.id,
    for (final spec in manifest.tools) spec.id,
  };

  static void _checkEntryPath(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw PluginException('插件包路径不合法：$name');
    }
    if (name.length > 160) throw PluginException('插件包路径过长：$name');
    final segments = name.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw PluginException('插件包路径逃逸：$name');
      }
    }
    if (name == 'plugin.json') return;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(segments.first)) {
      throw PluginException('插件包路径不合法：$name');
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final index = await _index();
    if (builtinPluginIds.contains(id)) {
      final builtin = builtinPlugins
          .where((plugin) => plugin.id == id)
          .firstOrNull;
      if (builtin == null) throw PluginException('未知内置插件：$id');
      index[id] = {'name': builtin.name, 'enabled': enabled};
    } else {
      final state = index[id];
      if (state == null) throw PluginException('插件未安装：$id');
      index[id] = {...state, 'enabled': enabled};
    }
    await _writeIndex(index);
  }

  /// 卸载拒绝新任务，但保留磁盘版本：已 pin 的任务与历史仍需读取这些代码。
  Future<void> uninstall(String id) async {
    if (builtinPluginIds.contains(id)) throw PluginException('内置插件不可卸载：$id');
    final index = await _index();
    if (!index.containsKey(id)) throw PluginException('插件未安装：$id');
    index.remove(id);
    await _writeIndex(index);
  }

  /// 磁盘上保留的全部版本（含已禁用/已卸载），按插件 ID 分组。
  Future<List<PluginInstallation>> allInstallations() async {
    if (kIsWeb) return const [];
    final root = _root;
    if (!await root.exists()) return const [];
    final installations = <PluginInstallation>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      if (id.startsWith('.') || builtinPluginIds.contains(id)) continue;
      for (final version in await _versionsOf(id)) {
        final manifest = await _manifestAt(id, version);
        if (manifest == null) continue;
        installations.add(
          PluginInstallation(
            plugin: InstalledPlugin(
              id: id,
              name: manifest.name,
              version: version,
              manifest: manifest,
            ),
            directory: _versionDir(id, version),
            version: version,
          ),
        );
      }
    }
    return installations;
  }

  /// registry 启动时读取：启用且磁盘存在的当前版本，附版本目录。
  Future<List<PluginInstallation>> activeInstallations() async {
    final installations = <PluginInstallation>[];
    for (final plugin in await list()) {
      if (plugin.builtIn || !plugin.enabled) continue;
      final manifest = await _manifestAt(plugin.id, plugin.version);
      if (manifest == null) continue;
      installations.add(
        PluginInstallation(
          plugin: plugin,
          directory: _versionDir(plugin.id, plugin.version),
          version: plugin.version,
        ),
      );
    }
    return installations;
  }

  /// 读取指定版本的安装目录，用于版本 pin；版本缺失返回 null。
  Future<PluginInstallation?> installationAt(String id, String version) async {
    if (!_looksLikeVersion(version)) return null;
    final manifest = await _manifestAt(id, version);
    if (manifest == null) return null;
    return PluginInstallation(
      plugin: InstalledPlugin(
        id: id,
        name: manifest.name,
        version: version,
        manifest: manifest,
      ),
      directory: _versionDir(id, version),
      version: version,
    );
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // 清理失败不影响已完成的安装。
    }
  }
}
