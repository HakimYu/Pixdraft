import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

String newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

enum ApiProtocol { images, responses, wavespeed, evolink;
  bool get isAsync => this == wavespeed || this == evolink;
  String get label => switch (this) { images => 'Images', responses => 'Responses', wavespeed => 'WaveSpeed', evolink => 'EvoLink' };
}
enum TransportMode { auto, stream, json }
enum TaskStatus { queued, running, done, error, partialError, aborted, interrupted }

class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.models,
    this.enabled = true,
    this.allowHttp = false,
    this.protocol = ApiProtocol.images,
    this._adapterId,
    this.adapterVersion,
    this.pluginConfig = const {},
    this.imageModel = 'gpt-image-1',
    this.responseModel = 'gpt-4.1',
    this.toolModel = 'gpt-image-1',
    this.transport = TransportMode.auto,
    this.fileInput = false,
    this.promptCompatibility = false,
    this.timeoutSeconds = 900,
    this.partialImages = 1,
    this.safetyIdentifier = '',
  });
  final List<String>? models;
  List<String> get enabledModels => models ?? {imageModel, if (protocol == ApiProtocol.responses) ...[responseModel, toolModel]}.toList();
  final String id, name, baseUrl, imageModel, responseModel, toolModel, safetyIdentifier;
  final bool enabled, allowHttp, fileInput, promptCompatibility;
  final ApiProtocol protocol;

  final String? _adapterId;

  /// 实际执行适配器扩展 ID；旧配置缺省等于 [protocol] 名称。
  String get adapterId => _adapterId ?? protocol.name;

  /// 固定使用的插件版本；为空表示使用当前启用版本。
  final String? adapterVersion;

  /// 插件私有配置，由插件字段描述约束。
  final Map<String, dynamic> pluginConfig;
  final TransportMode transport;
  final int timeoutSeconds, partialImages;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl, 'models': enabledModels, 'enabled': enabled, 'allowHttp': allowHttp, 'protocol': protocol.name, 'adapterId': adapterId, 'adapterVersion': adapterVersion, 'pluginConfig': pluginConfig, 'imageModel': imageModel, 'responseModel': responseModel, 'toolModel': toolModel, 'transport': transport.name, 'fileInput': fileInput, 'promptCompatibility': promptCompatibility, 'timeoutSeconds': timeoutSeconds, 'partialImages': partialImages, 'safetyIdentifier': safetyIdentifier};
  factory ProviderConfig.fromJson(Map<String, dynamic> j) {
final rawProtocol = (j['protocol'] as String?)?.trim();
    final protocol = apiProtocolByName(rawProtocol);
    final rawAdapter = (j['adapterId'] as String?)?.trim();
    // 未知协议名不得被静默改写：保留原始字符串作为 adapterId，执行侧据此拒绝。
    final adapterId = rawAdapter != null && rawAdapter.isNotEmpty ? rawAdapter : (rawProtocol != null && rawProtocol.isNotEmpty ? rawProtocol : null);
    return ProviderConfig(id: j['id'] as String, name: j['name'] as String, baseUrl: j['baseUrl'] as String, models: (j['models'] as List?)?.cast<String>().map((id) => id.trim()).where((id) => id.isNotEmpty).toSet().toList(), enabled: j['enabled'] as bool? ?? true, allowHttp: j['allowHttp'] as bool? ?? false, protocol: protocol, adapterId: adapterId, adapterVersion: j['adapterVersion'] as String?, pluginConfig: (j['pluginConfig'] as Map?)?.map((key, value) => MapEntry(key.toString(), value)) ?? const {}, imageModel: j['imageModel'] as String? ?? 'gpt-image-1', responseModel: j['responseModel'] as String? ?? 'gpt-4.1', toolModel: j['toolModel'] as String? ?? 'gpt-image-1', transport: TransportMode.values.byName(j['transport'] as String? ?? 'auto'), fileInput: j['fileInput'] as bool? ?? false, promptCompatibility: j['promptCompatibility'] as bool? ?? false, timeoutSeconds: j['timeoutSeconds'] as int? ?? 900, partialImages: j['partialImages'] as int? ?? 1, safetyIdentifier: j['safetyIdentifier'] as String? ?? '');
  }
  String? validate() {
    final uri = Uri.tryParse(baseUrl);
    if (name.trim().isEmpty) return '请输入供应商名称';
    if (uri == null || uri.host.isEmpty || !['https', 'http'].contains(uri.scheme) || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return '请输入不含凭据、查询或片段的 API 地址';
    if (uri.scheme == 'http' && !allowHttp) return '使用 HTTP 前请明确开启不安全连接';
    if (timeoutSeconds < 1 || timeoutSeconds > 3600) return '超时需为 1–3600 秒';
    if (partialImages < 0 || partialImages > 3) return '预览帧数需为 0–3';
    if (imageModel.trim().isEmpty || responseModel.trim().isEmpty || toolModel.trim().isEmpty) return '模型 ID 不能为空';
    if (adapterId.trim().isEmpty) return '适配器 ID 不能为空';
    return null;
  }
  /// 固定插件版本或改写插件私有配置；其余字段按原样保留。
  ProviderConfig copyWith({String? adapterVersion, Map<String, dynamic>? pluginConfig}) => ProviderConfig(id: id, name: name, baseUrl: baseUrl, models: models, enabled: enabled, allowHttp: allowHttp, protocol: protocol, adapterId: adapterId, adapterVersion: adapterVersion ?? this.adapterVersion, pluginConfig: pluginConfig ?? this.pluginConfig, imageModel: imageModel, responseModel: responseModel, toolModel: toolModel, transport: transport, fileInput: fileInput, promptCompatibility: promptCompatibility, timeoutSeconds: timeoutSeconds, partialImages: partialImages, safetyIdentifier: safetyIdentifier);
}

/// 未知协议名回落到可读取的旧默认值；执行侧按 [ProviderConfig.adapterId] 严格查找，不做兜底生图。
ApiProtocol apiProtocolByName(String? name) => ApiProtocol.values.firstWhere((value) => value.name == name, orElse: () => ApiProtocol.images);

class GenerationParams {
const GenerationParams({this.size = 'auto', this.quality = 'auto', this.count = 1, this.format = 'png', this.compression = 100, this.background = 'auto', this.moderation = 'auto', this.inputFidelity = 'high', this.complexity = '', this.gifFrames = 9, this.gifDuration = 200, this.extra = const {}});
  final String size, quality, format, background, moderation, inputFidelity, complexity;
  final int count, compression, gifFrames, gifDuration;

  /// 插件字段扩展参数，旧配置为空。
  final Map<String, dynamic> extra;
  Map<String, dynamic> toJson() => {'size': size, 'quality': quality, 'count': count, 'format': format, 'compression': compression, 'background': background, 'moderation': moderation, 'inputFidelity': inputFidelity, 'complexity': complexity, 'gifFrames': gifFrames, 'gifDuration': gifDuration, 'extra': extra};
  factory GenerationParams.fromJson(Map<String, dynamic> j) => GenerationParams(size: j['size'] as String? ?? 'auto', quality: j['quality'] as String? ?? 'auto', count: j['count'] as int? ?? 1, format: j['format'] as String? ?? 'png', compression: j['compression'] as int? ?? 100, background: j['background'] as String? ?? 'auto', moderation: j['moderation'] as String? ?? 'auto', inputFidelity: j['inputFidelity'] as String? ?? 'high', complexity: j['complexity'] as String? ?? '', gifFrames: j['gifFrames'] as int? ?? 9, gifDuration: j['gifDuration'] as int? ?? 200, extra: (j['extra'] as Map?)?.map((key, value) => MapEntry(key.toString(), value)) ?? const {});
}

class ImageAsset {
  const ImageAsset({required this.id, required this.path, required this.mime, required this.hash, required this.bytes, this.remoteUrl, this.width, this.height});
  final String id, path, mime, hash;
  final String? remoteUrl;
  final int bytes;
  final int? width, height;
  Map<String, dynamic> toJson() => {'id': id, 'path': path, 'mime': mime, 'hash': hash, 'bytes': bytes, 'remoteUrl': remoteUrl, 'width': width, 'height': height};
  factory ImageAsset.fromJson(Map<String, dynamic> j) => ImageAsset(id: j['id'] as String, path: j['path'] as String, mime: j['mime'] as String, hash: j['hash'] as String, bytes: j['bytes'] as int, remoteUrl: j['remoteUrl'] as String?, width: j['width'] as int?, height: j['height'] as int?);
}

/// 一条已固定的预/后处理步骤；版本随任务快照保存，不随插件更新漂移。
class ProcessingStep {
  const ProcessingStep({required this.pluginId, required this.version, required this.processorId, this.params = const {}});
  final String pluginId, version, processorId;
  final Map<String, dynamic> params;
  Map<String, dynamic> toJson() => {'pluginId': pluginId, 'version': version, 'processorId': processorId, 'params': params};
  factory ProcessingStep.fromJson(Map<String, dynamic> j) => ProcessingStep(pluginId: j['pluginId'] as String? ?? '', version: j['version'] as String? ?? '', processorId: j['processorId'] as String? ?? '', params: (j['params'] as Map?)?.map((key, value) => MapEntry(key.toString(), value)) ?? const {});
}

class GenerationInput {
  const GenerationInput({required this.taskId, required this.provider, required this.prompt, required this.params, this.references = const [], this.mask, this.markup, this.parentTaskId, this.parentAssetId, this.preprocessors = const [], this.postprocessors = const []});
  final String taskId, prompt;
  final ProviderConfig provider;
  final GenerationParams params;
  final List<ImageAsset> references;
  final ImageAsset? mask, markup;
  final String? parentTaskId, parentAssetId;

  /// 有序生成前处理链；空表示直接使用 [references]。
  final List<ProcessingStep> preprocessors;

  /// 有序生成后处理链；空表示不做处理。
  final List<ProcessingStep> postprocessors;
  Map<String, dynamic> toJson() => {'taskId': taskId, 'provider': provider.toJson(), 'prompt': prompt, 'params': params.toJson(), 'references': references.map((e) => e.toJson()).toList(), 'mask': mask?.toJson(), 'markup': markup?.toJson(), 'parentTaskId': parentTaskId, 'parentAssetId': parentAssetId, 'preprocessors': preprocessors.map((e) => e.toJson()).toList(), 'postprocessors': postprocessors.map((e) => e.toJson()).toList()};
  factory GenerationInput.fromJson(Map<String, dynamic> j) => GenerationInput(taskId: j['taskId'] as String, provider: ProviderConfig.fromJson(Map<String, dynamic>.from(j['provider'] as Map)), prompt: j['prompt'] as String, params: GenerationParams.fromJson(Map<String, dynamic>.from(j['params'] as Map)), references: (j['references'] as List? ?? []).map((e) => ImageAsset.fromJson(Map<String, dynamic>.from(e as Map))).toList(), mask: j['mask'] == null ? null : ImageAsset.fromJson(Map<String, dynamic>.from(j['mask'] as Map)), markup: j['markup'] == null ? null : ImageAsset.fromJson(Map<String, dynamic>.from(j['markup'] as Map)), parentTaskId: j['parentTaskId'] as String?, parentAssetId: j['parentAssetId'] as String?, preprocessors: (j['preprocessors'] as List? ?? []).map((e) => ProcessingStep.fromJson(Map<String, dynamic>.from(e as Map))).toList(), postprocessors: (j['postprocessors'] as List? ?? []).map((e) => ProcessingStep.fromJson(Map<String, dynamic>.from(e as Map))).toList());
  GenerationInput copyWith({ProviderConfig? provider, GenerationParams? params, List<ImageAsset>? references, ImageAsset? mask, ImageAsset? markup, List<ProcessingStep>? preprocessors, List<ProcessingStep>? postprocessors}) => GenerationInput(taskId: taskId, provider: provider ?? this.provider, prompt: prompt, params: params ?? this.params, references: references ?? this.references, mask: mask ?? this.mask, markup: markup ?? this.markup, parentTaskId: parentTaskId, parentAssetId: parentAssetId, preprocessors: preprocessors ?? this.preprocessors, postprocessors: postprocessors ?? this.postprocessors);
}

class GenerationEvent {
  const GenerationEvent(this.kind, {this.bytes, this.url, this.mime = 'image/png', this.key, this.message, this.metadata = const {}});
  final String kind; // started, preview, image, metadata, done
  final Uint8List? bytes;
  final String? url, key, message;
  final String mime;
  final Map<String, dynamic> metadata;
}

abstract class GenerationClient {
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey);
  void cancel(String taskId);
}

class StudioTask {
  const StudioTask({required this.input, required this.status, required this.createdAt, this.outputs = const [], this.favorite = false, this.categoryId, this.deletedAt, this.error, this.attempt = 0});
  final GenerationInput input;
  final TaskStatus status;
  final DateTime createdAt;
  final List<ImageAsset> outputs;
  final bool favorite;
  final String? categoryId, error;
  final DateTime? deletedAt;
  final int attempt;
  String get id => input.taskId;
}

Map<String, dynamic> decodeObject(String value) => Map<String, dynamic>.from(jsonDecode(value) as Map);
