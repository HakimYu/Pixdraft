import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image_gen/api/openai_client.dart';
import 'package:image_gen/models/models.dart';

typedef FakeHandler = Future<ResponseBody> Function(
  RequestOptions options,
  Future<void>? cancelFuture,
);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FakeHandler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object body, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

ResponseBody errorBody(int status, String message) {
  return jsonBody({
    'error': {'message': message},
  }, status: status);
}

ResponseBody sseBody(String text) {
  return ResponseBody.fromString(
    text,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}

ResponseBody streamBody(Stream<Uint8List> stream) {
  return ResponseBody(
    stream,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream; charset=utf-8'],
    },
  );
}

class DrainResult {
  DrainResult(this.events, this.error);

  final List<GenerationEvent> events;
  final Object? error;

  List<GenerationEvent> ofKind(String kind) =>
      events.where((event) => event.kind == kind).toList();
}

Future<DrainResult> drain(Stream<GenerationEvent> stream) async {
  final events = <GenerationEvent>[];
  Object? error;
  try {
    await for (final event in stream) {
      events.add(event);
    }
  } catch (caught) {
    error = caught;
  }
  return DrainResult(events, error);
}

String b64(List<int> bytes) => base64Encode(bytes);

final List<int> samplePng = const [1, 2, 3, 4, 5];

late Directory apiTempDir;
late File referenceFile;
late File maskFile;

Future<void> setUpApiFiles() async {
  apiTempDir = await Directory.systemTemp.createTemp('image_gen_api_test_');
  referenceFile = File('${apiTempDir.path}/reference.png');
  maskFile = File('${apiTempDir.path}/mask.png');
  await referenceFile.writeAsBytes(samplePng);
  await maskFile.writeAsBytes(samplePng);
}

Future<void> tearDownApiFiles() async {
  await apiTempDir.delete(recursive: true);
}

File fileFor(ImageAsset asset) => File(asset.path);

ImageAsset referenceAsset() => ImageAsset(
  id: 'ref-1',
  path: referenceFile.path,
  mime: 'image/png',
  hash: 'hash-ref-1',
  bytes: samplePng.length,
  remoteUrl: '',
  width: 1,
  height: 1,
);

ImageAsset maskAsset() => ImageAsset(
  id: 'mask-1',
  path: maskFile.path,
  mime: 'image/png',
  hash: 'hash-mask-1',
  bytes: samplePng.length,
  remoteUrl: '',
  width: 1,
  height: 1,
);

ProviderConfig testProvider({
  String baseUrl = 'https://api.example.test',
  bool allowHttp = false,
  ApiProtocol protocol = ApiProtocol.images,
  TransportMode transport = TransportMode.json,
  bool fileInput = false,
  bool promptCompatibility = false,
  int timeoutSeconds = 900,
  String imageModel = 'gpt-image-1',
  String responseModel = 'gpt-4.1',
  String toolModel = 'gpt-image-1',
}) {
  return ProviderConfig(
    id: 'provider-1',
    name: 'Provider 1',
    baseUrl: baseUrl,
    allowHttp: allowHttp,
    protocol: protocol,
    imageModel: imageModel,
    responseModel: responseModel,
    toolModel: toolModel,
    transport: transport,
    fileInput: fileInput,
    promptCompatibility: promptCompatibility,
    timeoutSeconds: timeoutSeconds,
  );
}

GenerationInput testInput({
  required ProviderConfig provider,
  required String prompt,
  GenerationParams? params,
  List<ImageAsset> references = const [],
  ImageAsset? mask,
  ImageAsset? markup,
}) {
  return GenerationInput(
    taskId: 'task-1',
    provider: provider,
    prompt: prompt,
    params: params ?? const GenerationParams(),
    references: references,
    mask: mask,
    markup: markup,
  );
}

Dio fakeDio(FakeAdapter adapter) => Dio()..httpClientAdapter = adapter;

OpenAiClient clientFor(FakeAdapter adapter) =>
    OpenAiClient(readAsset: (asset) => fileFor(asset).readAsBytes(), assetLength: (asset) => fileFor(asset).length(), dio: fakeDio(adapter));

bool isCancel(DioException error) => error.type == DioExceptionType.cancel;
