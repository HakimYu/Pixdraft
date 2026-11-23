import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/data/studio_store.dart';
import 'package:image_gen/features/updates/app_updates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _latest = 'https://api.github.com/repos/HakimYu/Pixdraft/releases/latest';
const _download =
    'https://github.com/HakimYu/Pixdraft/releases/download/v1.10.0/';
const _manifestName = 'pixdraft-update.json';
const _package = 'Pixdraft.apk';
const _nodes = '''export const PROXY_NODES: Partial<DomainNode>[] = [
  { label: "contribute", value: "mirror.example.com" },
];''';

String _via(String host, String url) => 'https://$host/$url';

ResponseBody _reply(Object data, [int status = 200]) =>
    ResponseBody.fromString(data is String ? data : jsonEncode(data), status);

ResponseBody _release(
  String tag, {
  bool signed = true,
  bool prerelease = false,
}) => _reply({
  'tag_name': tag,
  'draft': false,
  'prerelease': prerelease,
  'body': 'GitHub notes',
  'assets': [
    if (signed) ...[
      {'name': _manifestName},
      {'name': '$_manifestName.sig'},
    ],
  ],
});

class _Adapter implements HttpClientAdapter {
  FutureOr<ResponseBody> Function(String) respond = (_) => _reply('', 503);
  final requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requests.add(url);
    return respond(url);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  final automatic = UpdatePreferences(null);
  final github = UpdatePreferences({'source': 'github'});
  final custom = UpdatePreferences({
    'source': 'custom',
    'host': 'mirror.example.com',
  });
  late Directory directory;
  late StudioStore store;
  late _Adapter adapter;
  late AppUpdates updates;
  late Signature signature;
  final package = utf8.encode('test apk bytes');
  final manifest = jsonEncode({
    'repository': 'HakimYu/Pixdraft',
    'tag': 'v1.10.0',
    'notes': 'Signed notes',
    'assets': [
      {
        'name': _package,
        'platform': 'android',
        'size': package.length,
        'sha256': crypto.sha256.convert(package).toString(),
      },
    ],
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pixdraft-updates-test-');
    store = await StudioStore.open(
      factory: databaseFactoryFfi,
      directory: directory,
    );
    final key = await Ed25519().newKeyPair();
    signature = await Ed25519().sign(utf8.encode(manifest), keyPair: key);
    adapter = _Adapter();
    updates = AppUpdates(
      store,
      dio: Dio()..httpClientAdapter = adapter,
      publicKey: await key.extractPublicKey(),
    );
  });

  tearDown(() async {
    updates.close();
    await store.close();
    await directory.delete(recursive: true);
  });

  ResponseBody signedFiles(String url) {
    if (url.endsWith('/$_manifestName')) return _reply(manifest);
    if (url.endsWith('/$_manifestName.sig')) {
      return ResponseBody.fromBytes(signature.bytes, 200);
    }
    return _reply('', 503);
  }

  test('compares numeric versions and ignores the installed build number', () {
    expect(versionNumber('v1.10.0')! > versionNumber('1.9.9+12')!, isTrue);
    expect(versionNumber('1.0.0+2'), versionNumber('v1.0.0'));
    expect(versionNumber('v1.0.1-beta.1'), isNull);
  });

  test(
    'extracts and deduplicates only HTTPS mirror hosts in the upstream list',
    () {
      expect(
        parseMirrorNodes('''export const PROXY_NODES = [
      { value: "mirror.example.com" }, { value: "HTTPS://MIRROR.example.com/" },
      { value: "http://mirror.example.com" }, { value: "127.0.0.1" },
      { value: "office.local" }, { value: "host.example.com/path" },
    ]; const outside = [{ value: "outside.example.com" }];'''),
        ['mirror.example.com'],
      );
    },
  );

  test('GitHub-only check handles no release, same version and unsigned new release', () async {
    adapter.respond = (_) => _reply('', 404);
    expect(
      (await updates.check('1.0.0', github)).status,
      UpdateStatus.noRelease,
    );
    adapter.respond = (_) => _release('v1.0.0');
    expect(
      (await updates.check('1.0.0+2', github)).status,
      UpdateStatus.current,
    );
    adapter.respond = (_) => _release('v1.10.0', signed: false);
    final result = await updates.check('1.0.0', github);
    expect(result.status, UpdateStatus.available);
    expect(result.release!.assets, isEmpty);
    expect(
      result.release!.page.toString(),
      'https://github.com/HakimYu/Pixdraft/releases/tag/v1.10.0',
    );
    expect(adapter.requests, everyElement(_latest));
  });

  test(
    'a signed mirror can finish before the parallel GitHub request',
    () async {
      final official = Completer<ResponseBody>();
      final mirror = builtInMirrors.first;
      adapter.respond = (url) {
        if (url == _latest) return official.future;
        if (url == _via(mirror, _latest)) return _release('v1.10.0');
        return signedFiles(url);
      };
      try {
        final result = await updates
            .check('1.0.0', automatic)
            .timeout(const Duration(seconds: 3));
        expect(result.status, UpdateStatus.available);
        expect(result.release!.notes, 'Signed notes');
        expect(result.release!.mirror, mirror);
        expect(adapter.requests, contains(_latest));
        expect(adapter.requests, isNot(contains(contains('nodes.ts'))));
      } finally {
        official.complete(_reply('', 503));
      }
    },
  );

  test('stale, prerelease and tampered custom mirror results cannot confirm a version', () async {
    final host = custom.host!;
    for (final (tag, prerelease) in [
      ('v1.0.0', false),
      ('v1.10.0', true),
      ('v1.10.0', false),
    ]) {
      adapter.respond = (url) {
        if (url == _via(host, _latest)) {
          return _release(tag, prerelease: prerelease);
        }
        if (url == _via(host, '$_download$_manifestName')) {
          return _reply('$manifest ');
        }
        return signedFiles(url);
      };
      expect(
        (await updates.check('1.0.0', custom)).status,
        UpdateStatus.unconfirmed,
      );
    }
    expect(adapter.requests.map((url) => Uri.parse(url).host).toSet(), {
      'api.github.com',
      host,
    });
  });

  test('automatic mode discovers and caches Akams nodes after the built-in API fails', () async {
    final host = custom.host!;
    adapter.respond = (url) {
      if (url.endsWith('nodes.ts')) return _reply(_nodes);
      if (url == _via(host, _latest)) return _release('v1.10.0');
      return signedFiles(url);
    };
    expect((await updates.check('1.0.0', automatic)).release?.mirror, host);
    expect(await updates.cachedMirrors(), [host]);
    expect(
      adapter.requests.indexWhere((url) => url.endsWith('nodes.ts')),
      greaterThan(
        adapter.requests.indexOf(_via(builtInMirrors.first, _latest)),
      ),
    );
    adapter.requests.clear();
    expect((await updates.check('1.0.0', automatic)).release?.mirror, host);
    expect(adapter.requests, isNot(contains(contains('nodes.ts'))));
  });

  test('official metadata uses a verified mirror manifest and corrupt downloads fall back', () async {
    final host = custom.host!;
    adapter.respond = (url) {
      if (url == _latest) return _release('v1.10.0');
      if (url.startsWith('https://$host/')) return signedFiles(url);
      return _reply('', 503);
    };
    final release = (await updates.check('1.0.0', custom)).release!;
    expect(release.mirror, host);
    final asset = release.assets.single;
    final fileUrl = '$_download$_package';
    adapter.respond = (url) => url == fileUrl
        ? ResponseBody.fromBytes(List.filled(package.length, 0), 200)
        : ResponseBody.fromBytes(package, 200);
    final folder = await directory.createTemp('download-');
    final file = await updates.download(
      release,
      asset,
      folder,
      custom,
      cancel: CancelToken(),
      onProgress: (_) {},
    );
    expect(await file.readAsBytes(), package);
    expect(adapter.requests.sublist(adapter.requests.length - 2), [
      fileUrl,
      _via(host, fileUrl),
    ]);

    adapter.respond = (_) =>
        ResponseBody.fromBytes(List.filled(package.length + 1, 0), 200);
    await expectLater(
      updates.download(
        release,
        asset,
        folder,
        github,
        cancel: CancelToken(),
        onProgress: (_) {},
      ),
      throwsStateError,
    );
    expect(await file.exists(), isFalse);
  });
}
