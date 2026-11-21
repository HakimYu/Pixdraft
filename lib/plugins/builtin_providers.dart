import 'package:dio/dio.dart';

import '../api/openai_client.dart';
import '../api/params.dart';
import '../data/studio_store.dart';
import '../features/providers/provider_connection.dart';
import '../models/models.dart';
import 'plugin_contract.dart';
import 'plugin_manifest.dart';

/// 内置提供商插件：四个适配器复用原有协议引擎，只补上插件契约的元数据。
const String builtinProvidersPluginId = 'builtin.providers';
const String builtinProvidersVersion = builtinPluginVersion;

const ProviderDescriptor imagesDescriptor = ProviderDescriptor(
  id: 'images',
  pluginId: builtinProvidersPluginId,
  version: builtinProvidersVersion,
  name: 'OpenAI Images',
  defaultBaseUrl: 'https://api.openai.com/v1',
  defaultModel: 'gpt-image-1',
);

const ProviderDescriptor responsesDescriptor = ProviderDescriptor(
  id: 'responses',
  pluginId: builtinProvidersPluginId,
  version: builtinProvidersVersion,
  name: 'OpenAI Responses',
  defaultBaseUrl: 'https://api.openai.com/v1',
  defaultModel: 'gpt-4.1',
);

const ProviderDescriptor wavespeedDescriptor = ProviderDescriptor(
  id: 'wavespeed',
  pluginId: builtinProvidersPluginId,
  version: builtinProvidersVersion,
  name: 'WaveSpeed',
  defaultBaseUrl: 'https://api.wavespeed.ai/api/v3',
  defaultModel: 'bytedance/seedream-v5.5/edit',
);

const ProviderDescriptor evolinkDescriptor = ProviderDescriptor(
  id: 'evolink',
  pluginId: builtinProvidersPluginId,
  version: builtinProvidersVersion,
  name: 'EvoLink',
  defaultBaseUrl: 'https://api.evolink.ai/v1',
  defaultModel: 'doubao-seedream-5.5',
);

/// 四个内置适配器，extension ID 与 [ApiProtocol.name] 一致，兼容既有配置。
List<ProviderExtension> createBuiltinProviders(StudioStore store) => [
  BuiltinProvider(
    descriptor: imagesDescriptor,
    protocol: ApiProtocol.images,
    store: store,
  ),
  BuiltinProvider(
    descriptor: responsesDescriptor,
    protocol: ApiProtocol.responses,
    store: store,
  ),
  BuiltinProvider(
    descriptor: wavespeedDescriptor,
    protocol: ApiProtocol.wavespeed,
    store: store,
  ),
  BuiltinProvider(
    descriptor: evolinkDescriptor,
    protocol: ApiProtocol.evolink,
    store: store,
  ),
];

/// 复用 [OpenAiClient] 的内置适配器；请求、轮询、SSE 与降级规则都留在原引擎。
class BuiltinProvider implements ProviderExtension {
  BuiltinProvider({
    required this.descriptor,
    required this.protocol,
    required StudioStore store,
    Dio? dio,
  }) : _dio = dio,
       _client = OpenAiClient(readAsset: store.readAsset, assetLength: store.assetLength, dio: dio);

  @override
  final ProviderDescriptor descriptor;

  /// 该适配器对应的协议；配置里的 adapterId 已经决定路由，这里用于能力描述。
  final ApiProtocol protocol;
  final OpenAiClient _client;
  final Dio? _dio;

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) =>
      _client.generate(_routed(input), apiKey);

  /// adapterId 是权威路由：把配置里的 protocol 规范成该适配器实际的协议，
  /// 其余字段（baseUrl、模型、adapterVersion、pluginConfig、输入链）保持不变。
  GenerationInput _routed(GenerationInput input) {
    final provider = _normalizedProvider(input.provider);
    return identical(provider, input.provider)
        ? input
        : input.copyWith(provider: provider);
  }

  ProviderConfig _normalizedProvider(ProviderConfig provider) {
    if (provider.protocol == protocol && provider.adapterId == descriptor.id) {
      return provider;
    }
    return ProviderConfig.fromJson({
      ...provider.toJson(),
      'protocol': protocol.name,
      'adapterId': descriptor.id,
    });
  }

  @override
  void cancel(String taskId) => _client.cancel(taskId);

  @override
  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  }) {
    // 只描述协议能力；是否启用预览/文件上传由 provider 配置决定，不由这里代为关闭。
    switch (protocol) {
      case ApiProtocol.images:
        return GenerationCapabilities(
          maxReferences: 16,
          supportsMask: true,
          supportsMarkup: true,
          supportsPreview: true,
          qualities: _qualityOptions(provider.imageModel),
        );
      case ApiProtocol.responses:
        return GenerationCapabilities(
          maxReferences: 16,
          // Responses 图像工具支持蒙版（引擎上传 mask 并写入请求），但不支持标注。
          supportsMask: true,
          supportsPreview: true,
          supportsFileInput: true,
          usesResponseModel: true,
          qualities: _qualityOptions(provider.toolModel),
        );
      case ApiProtocol.wavespeed:
      case ApiProtocol.evolink:
        return GenerationCapabilities(
          maxReferences: 10,
          supportsPreview: false,
          supportsCustomSize: false,
          qualities: const ['auto', '1K', '1.5K', '2K'],
          formats: const ['png', 'jpeg'],
          sizes: aspectRatiosFor(protocol),
        );
    }
  }

  List<String> _qualityOptions(String model) => [
    'auto',
    'low',
    'medium',
    'high',
    if (isGptImage25Model(model)) ...['xhigh', 'max'],
  ];

  @override
  Future<GenerationPlan> plan(GenerationInput input) async {
    final routed = _routed(input);
    final params = routed.params;
    if (params.count < 1 || params.count > 10) {
      throw const FormatException('生成数量需为 1–10');
    }
    final limit = protocol.isAsync ? 10 : 16;
    if (routed.references.length > limit) {
      throw FormatException('参考图最多 $limit 张');
    }
    if (protocol.isAsync && (routed.mask != null || routed.markup != null)) {
      throw const FormatException('当前协议不支持蒙版或标注，请清除编辑图层');
    }
    final model = protocol != ApiProtocol.responses
        ? routed.provider.imageModel
        : routed.provider.toolModel;
    // 与 OpenAiClient 使用同一套归一化：计划里落库的参数就是实际请求参数。
    final resolved = resolveParams(
      params,
      protocol: protocol,
      imageModel: model,
      hasInputImages: routed.references.isNotEmpty,
    );
    return GenerationPlan(
      input: routed.copyWith(
        params: GenerationParams(
          size: resolved.size,
          quality: resolved.quality,
          count: resolved.count,
          format: resolved.format,
          compression: resolved.compression,
          background: resolved.background,
          moderation: resolved.moderation,
          inputFidelity: resolved.inputFidelity ?? '',
          complexity: resolved.complexity ?? '',
          gifFrames: resolved.gifFrames,
          gifDuration: resolved.gifDuration,
          // 插件额外参数原样保留，不在归一化时丢失。
          extra: params.extra,
        ),
      ),
      expectedCount: resolved.count,
      metadata: {
        'adapterId': descriptor.id,
        'plugin': '$builtinProvidersPluginId@$builtinProvidersVersion',
        'protocol': protocol.name,
        'model': model,
      },
    );
  }

  @override
  Future<List<String>> discoverModels(
    ProviderConfig provider,
    String? apiKey,
  ) async {
    final checker = ProviderModelChecker(dio: _dio);
    try {
      final result = await checker.check(_normalizedProvider(provider), apiKey);
      switch (result.status) {
        case ModelCheckStatus.ok:
          return result.models;
        // 没有 /models 端点时保留手工输入，不当作失败。
        case ModelCheckStatus.noModelEndpoint:
          return const [];
        case ModelCheckStatus.unauthorized:
        case ModelCheckStatus.redirected:
        case ModelCheckStatus.invalidResponse:
        case ModelCheckStatus.failed:
          throw FormatException(result.message);
      }
    } finally {
      checker.close();
    }
  }
}