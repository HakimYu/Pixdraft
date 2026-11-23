import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';

import '../../data/studio_store.dart';

const updateSettingsKey = 'appUpdate';
const builtInMirrors = [
  'gh-proxy.com',
  'ghfast.top',
  'gh.nxnow.top',
  'ghproxy.net',
];
const _repo = 'HakimYu/Pixdraft';
const _nodesPath = 'hubporg/ghproxy-next';
const _nodeSources = [
  'https://raw.githubusercontent.com/$_nodesPath/main/components/nodes.ts',
  'https://cdn.jsdelivr.net/gh/$_nodesPath@main/components/nodes.ts',
];
const _mirrorCacheKey = 'appUpdateMirrors';
const _publicKeyHex =
    '984ea6195d76b146fa51fd587431e78da65145b15fb744db22e04145cfa826a3';
final _versionPattern = RegExp(
  r'^v?(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})(?:\+[0-9A-Za-z.-]+)?$',
);
final _domainPattern = RegExp(
  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$',
);
final _tagPattern = RegExp(
  r'^v?(?:0|[1-9]\d{0,8})\.(?:0|[1-9]\d{0,8})\.(?:0|[1-9]\d{0,8})$',
);
final _assetNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

BigInt? versionNumber(String value) {
  final match = _versionPattern.firstMatch(value);
  if (match == null) return null;
  final base = BigInt.from(1000000000);
  return (BigInt.parse(match[1]!) * base + BigInt.parse(match[2]!)) * base +
      BigInt.parse(match[3]!);
}

String? mirrorHost(String input) {
  final value = input.trim().toLowerCase();
  final host = value.startsWith('https://') ? value.substring(8) : value;
  final normalized = host.endsWith('/')
      ? host.substring(0, host.length - 1)
      : host;
  if (normalized.length > 253 ||
      !_domainPattern.hasMatch(normalized) ||
      normalized.endsWith('.local') ||
      normalized.endsWith('.localhost') ||
      normalized.endsWith('.internal') ||
      normalized.endsWith('.home.arpa')) {
    return null;
  }
  return normalized;
}

List<String> parseMirrorNodes(String source) {
  final list = RegExp(r'PROXY_NODES[^=]*=\s*\[([\s\S]*?)\];')
      .firstMatch(source)?[1];
  return {
    for (final match in RegExp(
      r'''\bvalue\s*:\s*["']([^"'\r\n]+)["']''',
    ).allMatches(list ?? ''))
      ?mirrorHost(match[1]!),
  }.take(100).toList();
}

enum UpdateSource { automatic, github, custom }

class UpdatePreferences {
  UpdatePreferences(Map<String, dynamic>? data)
    : automaticCheck = data?['automaticCheck'] != false,
      mode = switch (data?['source']) {
        'github' => UpdateSource.github,
        'custom' => UpdateSource.custom,
        _ => UpdateSource.automatic,
      },
      host = data?['host'] is String
          ? mirrorHost(data!['host'] as String)
          : null;

  final bool automaticCheck;
  final UpdateSource mode;
  final String? host;
}

class UpdateAsset {
  const UpdateAsset._(this.name, this.platform, this.size, this.sha256);
  final String name;
  final String platform;
  final int size;
  final String sha256;
}

class AppRelease {
  const AppRelease(this.tag, this.notes, {this.assets = const [], this.mirror});
  final String tag;
  final String notes;
  final List<UpdateAsset> assets;
  final String? mirror;
  Uri get page => Uri.https('github.com', '/$_repo/releases/tag/$tag');
}

enum UpdateStatus { available, current, noRelease, unconfirmed }

typedef UpdateResult = ({UpdateStatus status, AppRelease? release});
const _current = (status: UpdateStatus.current, release: null);
const _unknown = (status: UpdateStatus.unconfirmed, release: null);

class AppUpdates {
  AppUpdates(this.store, {Dio? dio, SimplePublicKey? publicKey})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 8),
            ),
          ),
      _publicKey =
          publicKey ??
          SimplePublicKey(
            List.generate(
              32,
              (index) => int.parse(
                _keyHex.substring(index * 2, index * 2 + 2),
                radix: 16,
              ),
            ),
            type: KeyPairType.ed25519,
          );

  static const _keyHex = _publicKeyHex;
  final StudioStore store;
  final Dio _dio;
  final SimplePublicKey _publicKey;
  Future<List<String>>? _refreshing;

  static final _latest = Uri.https(
    'api.github.com',
    '/repos/$_repo/releases/latest',
  );
  static Uri _asset(String tag, String file) =>
      Uri.https('github.com', '/$_repo/releases/download/$tag/$file');
  static Uri _via(Uri uri, String? mirror) =>
      mirror == null ? uri : Uri.parse('https://$mirror/$uri');

  void close() => _dio.close(force: true);

  Future<UpdateResult> check(
    String installed,
    UpdatePreferences preferences,
  ) async {
    final current = versionNumber(installed);
    if (current == null) return _unknown;
    final primary = switch (preferences.mode) {
      UpdateSource.automatic => builtInMirrors.first,
      UpdateSource.custom => preferences.host,
      UpdateSource.github => null,
    };
    final result = await _first([
      _checkSource(
        current,
        null,
        manifestFallbacks: switch (preferences.mode) {
          UpdateSource.automatic => builtInMirrors,
          UpdateSource.custom => [?preferences.host],
          UpdateSource.github => const [],
        },
      ),
      if (primary != null) _checkSource(current, primary),
    ]);
    if (result != null) return result;
    if (preferences.mode == UpdateSource.automatic) {
      final nodes = await _discoverMirrors();
      for (var index = 0; index < nodes.length && index < 12; index += 4) {
        final found = await _first([
          for (final host in nodes.skip(index).take(4))
            _checkSource(current, host),
        ]);
        if (found != null) return found;
      }
    }
    return _unknown;
  }

  Future<UpdateResult?> _checkSource(
    BigInt current,
    String? mirror, {
    List<String> manifestFallbacks = const [],
  }) async {
    final response = await _metadata(
      _via(_latest, mirror),
      followRedirects: mirror != null,
    );
    if (response == null) return null;
    if (mirror == null && response.status == 404) {
      return (status: UpdateStatus.noRelease, release: null);
    }
    if (response.status != 200) return null;
    try {
      final data = jsonDecode(utf8.decode(response.bytes));
      if (data is! Map ||
          data['draft'] != false ||
          data['prerelease'] != false) {
        return null;
      }
      final tag = data['tag_name'];
      if (tag is! String || !_tagPattern.hasMatch(tag)) return null;
      if (versionNumber(tag)! <= current) {
        return mirror == null ? _current : null;
      }
      final hasManifest = _hasManifest(data);
      if (mirror != null && !hasManifest) return null;
      final manifest = hasManifest
          ? await _signedRelease(tag, mirror) ??
                await _first([
                  for (final host in manifestFallbacks)
                    _signedRelease(tag, host),
                ])
          : null;
      final notes = data['body'];
      final release =
          manifest ??
          (mirror == null
              ? AppRelease(tag, notes is String ? notes : '')
              : null);
      return release == null
          ? null
          : (status: UpdateStatus.available, release: release);
    } on FormatException {
      return null;
    }
  }

  bool _hasManifest(Map data) {
    final assets = data['assets'];
    if (assets is! List) return false;
    final names = assets.whereType<Map>().map((asset) => asset['name']).toSet();
    return names.containsAll({
      'pixdraft-update.json',
      'pixdraft-update.json.sig',
    });
  }

  Future<AppRelease?> _signedRelease(String tag, String? mirror) async {
    final responses = await Future.wait([
      _metadata(_via(_asset(tag, 'pixdraft-update.json'), mirror)),
      _metadata(
        _via(_asset(tag, 'pixdraft-update.json.sig'), mirror),
        limit: 64,
      ),
    ]);
    final manifest = responses[0];
    final signature = responses[1];
    if (manifest?.status != 200 ||
        signature?.status != 200 ||
        signature!.bytes.length != 64) {
      return null;
    }
    if (!await Ed25519().verify(
      manifest!.bytes,
      signature: Signature(signature.bytes, publicKey: _publicKey),
    )) {
      return null;
    }
    try {
      final data = jsonDecode(utf8.decode(manifest.bytes));
      if (data is! Map ||
          data['repository'] != _repo ||
          data['tag'] != tag ||
          data['notes'] is! String ||
          data['assets'] is! List) {
        return null;
      }
      final assets = <UpdateAsset>[];
      final names = <String>{};
      for (final asset in data['assets'] as List) {
        if (asset is! Map) return null;
        final name = asset['name'];
        final size = asset['size'];
        final hash = asset['sha256'];
        final platform = asset['platform'];
        if (name is! String ||
            !_assetNamePattern.hasMatch(name) ||
            !names.add(name) ||
            platform is! String ||
            !const {
              'android',
              'macos',
              'windows',
              'linux',
            }.contains(platform) ||
            size is! int ||
            size <= 0 ||
            hash is! String ||
            !_hashPattern.hasMatch(hash)) {
          return null;
        }
        assets.add(UpdateAsset._(name, platform, size, hash));
      }
      return AppRelease(
        tag,
        data['notes'] as String,
        assets: List.unmodifiable(assets),
        mirror: mirror,
      );
    } on FormatException {
      return null;
    }
  }

  Future<List<String>> cachedMirrors() async {
    final data = await store.setting(_mirrorCacheKey);
    return _nodes(data);
  }

  List<String> _nodes(Map<String, dynamic>? data) {
    final values = data?['hosts'];
    if (values is! List) return const [];
    return {
      for (final value in values.whereType<String>())
        if (mirrorHost(value) case final host?)
          if (!builtInMirrors.contains(host)) host,
    }.take(100).toList();
  }

  Future<List<String>> _discoverMirrors() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final refresh = _refreshMirrors();
    _refreshing = refresh;
    try {
      return await refresh;
    } finally {
      _refreshing = null;
    }
  }

  Future<List<String>> _refreshMirrors() async {
    final data = await store.setting(_mirrorCacheKey);
    final cached = _nodes(data);
    final date = DateTime.tryParse(data?['updated']?.toString() ?? '');
    final now = DateTime.now();
    if (date != null &&
        !date.isAfter(now) &&
        now.difference(date) < const Duration(days: 1) &&
        cached.isNotEmpty) {
      return cached;
    }
    final refreshed = await _first([
      for (final source in _nodeSources) _readNodes(Uri.parse(source)),
    ]);
    if (refreshed == null) return cached;
    try {
      await store.saveSetting(_mirrorCacheKey, {
        'updated': now.toIso8601String(),
        'hosts': refreshed,
      });
    } on Exception {
      // 本次检查仍可使用刚获取的候选。
    }
    return refreshed;
  }

  Future<List<String>?> _readNodes(Uri url) async {
    final response = await _metadata(url);
    if (response?.status != 200) return null;
    final hosts = parseMirrorNodes(
      utf8.decode(response!.bytes, allowMalformed: true),
    ).where((host) => !builtInMirrors.contains(host)).toList();
    return hosts.isEmpty ? null : hosts;
  }

  Future<({int status, Uint8List bytes})?> _metadata(
    Uri url, {
    int limit = 1024 * 1024,
    bool followRedirects = true,
  }) async {
    final cancel = CancelToken();
    final timer = Timer(const Duration(seconds: 8), cancel.cancel);
    try {
      final response = await _dio.getUri<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: followRedirects,
          validateStatus: (status) => status == 200 || status == 404,
        ),
      );
      if (response.realUri.scheme != 'https' ||
          response.data == null ||
          response.statusCode == null) {
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream.timeout(
        const Duration(seconds: 8),
      )) {
        if (bytes.length + chunk.length > limit) return null;
        bytes.add(chunk);
      }
      return (status: response.statusCode!, bytes: bytes.takeBytes());
    } on Exception {
      return null;
    } finally {
      timer.cancel();
      cancel.cancel();
    }
  }

  Future<File> download(
    AppRelease release,
    UpdateAsset asset,
    Directory temp,
    UpdatePreferences preferences, {
    required void Function(int) onProgress,
    required CancelToken cancel,
  }) async {
    final target = File('${temp.path}${Platform.pathSeparator}${asset.name}');
    final url = _asset(release.tag, asset.name);
    final sources = switch (preferences.mode) {
      UpdateSource.github => <String?>{null},
      UpdateSource.custom => <String?>{null, preferences.host},
      UpdateSource.automatic => <String?>{
        null,
        if (release.mirror != null) release.mirror,
        ...builtInMirrors,
      },
    };
    for (final host in sources) {
      if (await _downloadFrom(
        _via(url, host),
        asset,
        target,
        onProgress,
        cancel,
      )) {
        return target;
      }
      if (cancel.isCancelled) throw StateError('下载已取消');
    }
    if (preferences.mode == UpdateSource.automatic) {
      for (final host in (await _discoverMirrors()).take(12)) {
        if (sources.contains(host)) continue;
        if (await _downloadFrom(
          _via(url, host),
          asset,
          target,
          onProgress,
          cancel,
        )) {
          return target;
        }
        if (cancel.isCancelled) throw StateError('下载已取消');
      }
    }
    throw StateError('未能下载通过校验的安装包');
  }

  Future<bool> _downloadFrom(
    Uri url,
    UpdateAsset asset,
    File file,
    void Function(int) progress,
    CancelToken cancel,
  ) async {
    if (cancel.isCancelled) return false;
    final attempt = CancelToken();
    unawaited(cancel.whenCancel.then((_) => attempt.cancel()));
    final timer = Timer(const Duration(minutes: 20), attempt.cancel);
    var verified = false;
    try {
      progress(0);
      final response = await _dio.getUri<ResponseBody>(
        url,
        cancelToken: attempt,
        options: Options(responseType: ResponseType.stream),
      );
      if (response.realUri.scheme != 'https' ||
          response.statusCode != 200 ||
          response.data == null) {
        return false;
      }
      var received = 0;
      final sink = file.openWrite();
      try {
        await sink.addStream(
          response.data!.stream.timeout(const Duration(seconds: 8)).map((
            chunk,
          ) {
            if (attempt.isCancelled) throw StateError('Download stopped');
            received += chunk.length;
            if (received > asset.size) {
              throw const FormatException('Unexpected package size');
            }
            progress(received);
            return chunk;
          }),
        );
      } finally {
        await sink.close();
      }
      if (cancel.isCancelled || received != asset.size) return false;
      verified =
          (await crypto.sha256.bind(file.openRead()).first).toString() ==
          asset.sha256;
      return verified;
    } on Object {
      return false;
    } finally {
      timer.cancel();
      attempt.cancel();
      if (!verified && await file.exists()) await file.delete();
    }
  }
}

Future<T?> _first<T extends Object>(List<Future<T?>> attempts) {
  final first = Completer<T?>();
  for (final attempt in attempts) {
    unawaited(
      attempt.then<void>((result) {
        if (result != null && !first.isCompleted) first.complete(result);
      }, onError: (Object _, StackTrace _) {}),
    );
  }
  unawaited(
    Future.wait(attempts.map((attempt) => attempt.onError((_, _) => null)))
        .then((_) {
          if (!first.isCompleted) first.complete(null);
        }),
  );
  return first.future;
}
