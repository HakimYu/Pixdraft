import '../models/models.dart';
import '../plugins/plugin_contract.dart';

const seedreamRatios = [
  '1:1',
  '1:2',
  '2:1',
  '1:3',
  '3:1',
  '2:3',
  '3:2',
  '3:4',
  '4:3',
  '4:5',
  '5:4',
  '9:16',
  '16:9',
  '9:21',
  '21:9',
];
const seedreamEvoRatios = [
  '1:1',
  '2:3',
  '3:2',
  '3:4',
  '4:3',
  '4:5',
  '5:4',
  '9:16',
  '16:9',
  '9:21',
  '21:9',
];
const _bananaRatios = [
  '1:1',
  '2:3',
  '3:2',
  '3:4',
  '4:3',
  '4:5',
  '5:4',
  '9:16',
  '16:9',
  '21:9',
  '1:4',
  '4:1',
  '1:8',
  '8:1',
];
const _seedreamTiers = ['1K', '1.5K', '2K'];
const _bananaTiers = ['0.5K', '1K', '2K', '4K'];
const _formats = ['png', 'jpeg'];
const _backgrounds = ['opaque', 'transparent'];
const _referenceMimes = ['image/jpeg', 'image/png', 'image/webp'];
const waveImageSchemaKey = 'wavespeedImageSchema';
String waveCatalogKey(String providerId) => 'wavespeedCatalog:$providerId';

class AsyncImageRules {
  const AsyncImageRules({
    this.confirmed = true,
    this.unsupported = false,
    this.requiresPrompt = true,
    this.referenceField,
    this.minReferences = 0,
    this.maxReferences,
    this.maxReferenceMb,
    this.referenceMimes,
    this.sizeField,
    this.requiredSize = false,
    this.requiredQuality = false,
    this.ratios = const [],
    this.pixelSize,
    this.sizeValues = const [],
    this.qualityField,
    this.qualities = const [],
    this.defaultQuality = 'auto',
    this.lowercaseQuality = false,
    this.formats = const [],
    this.backgrounds = const [],
    this.sendAutoBackground = false,
    this.forceTransparentPng = false,
    this.mask = false,
    this.extraFields = const [],
    this.requiredExtra = const {},
    this.integerExtra = const {},
  });

  final bool confirmed, unsupported, requiresPrompt;
  final bool requiredSize, requiredQuality;
  final String? referenceField, sizeField, qualityField, pixelSize;
  final int minReferences;
  final int? maxReferences, maxReferenceMb;
  final List<String>? referenceMimes;
  final List<String> ratios, sizeValues, qualities, formats, backgrounds;
  final String defaultQuality;
  final bool lowercaseQuality, sendAutoBackground, forceTransparentPng;
  final bool mask;
  final List<PluginField> extraFields;
  final Set<String> requiredExtra, integerExtra;

  GenerationCapabilities get capabilities => GenerationCapabilities(
    maxReferences: referenceField == null ? 0 : maxReferences ?? 64,
    supportsMask: mask,
    supportsCustomSize: pixelSize != null,
    qualities: qualities.isEmpty ? const [] : ['auto', ...qualities],
    formats: formats,
    sizes: ratios,
    extraFields: extraFields,
  );

  String resolveSize(String input) {
    final size = input.trim();
    if (sizeField == null) return 'auto';
    if (size == 'auto' && requiredSize)
      throw const FormatException('请选择当前模型的尺寸');
    if (size == 'auto' || ratios.contains(size) || sizeValues.contains(size))
      return size;
    final dimensions = RegExp(r'^(\d+)\s*[xX×*]\s*(\d+)$').firstMatch(size);
    final w = int.tryParse(dimensions?.group(1) ?? '') ?? 0;
    final h = int.tryParse(dimensions?.group(2) ?? '') ?? 0;
    final valid = switch (pixelSize) {
      'flux' => w >= 256 && h >= 256 && w <= 2048 && h <= 2048,
      'gpt' =>
        w > 0 &&
            h > 0 &&
            w <= 3840 &&
            h <= 3840 &&
            w % 16 == 0 &&
            h % 16 == 0 &&
            w * h >= 655360 &&
            w * h <= 8294400 &&
            w <= 3 * h &&
            h <= 3 * w,
      'seedream' =>
        w > 14 &&
            h > 14 &&
            w <= 16 * h &&
            h <= 16 * w &&
            w * h >= 921600 &&
            w * h <= 4624220,
      _ => false,
    };
    if (!valid) {
      if (pixelSize == 'flux')
        throw const FormatException('宽和高均需在 256–2048 像素之间');
      if (pixelSize == 'gpt')
        throw const FormatException(
          '像素宽高需为 16 的倍数，最长边至多 3840，总像素 655360–8294400，宽高比至多 3:1',
        );
      if (pixelSize == 'seedream')
        throw const FormatException(
          '请选择支持的比例，或输入总像素 921600–4624220、比例在 1:16–16:1 的宽高',
        );
      throw const FormatException('请选择当前模型支持的尺寸');
    }
    return pixelSize == 'flux' ? '$w*$h' : '${w}x$h';
  }

  String resolveQuality(String input) {
    if (qualities.isEmpty) return 'auto';
    final quality = input.trim().toLowerCase();
    if (quality == 'auto') {
      if (requiredQuality && defaultQuality == 'auto')
        throw const FormatException('请选择当前模型的分辨率');
      return defaultQuality;
    }
    for (final option in qualities) {
      if (option.toLowerCase() == quality) return option;
    }
    throw FormatException(
      '请选择当前模型支持的${qualityField == 'quality' && mask ? '画质' : '分辨率'}',
    );
  }

  String resolveFormat(String input, String background) {
    if (formats.isEmpty) return 'png';
    if (forceTransparentPng && background == 'transparent') return 'png';
    if (!formats.contains(input)) {
      final label = formats.map((format) => format.toUpperCase()).join(' / ');
      throw FormatException('当前模型仅支持 $label');
    }
    if (backgrounds.contains('transparent') &&
        background == 'transparent' &&
        input == 'jpeg') {
      throw const FormatException('透明背景请选择 PNG 或 WebP');
    }
    return input;
  }

  void validateInput(GenerationInput input) {
    if (unsupported) throw const FormatException('当前接口需要专用输入，创建页暂不支持');
    if (requiresPrompt && input.prompt.trim().isEmpty)
      throw const FormatException('当前模型需要提示词');
    if (input.params.count < 1 || input.params.count > 10)
      throw const FormatException('生成数量需为 1–10');
    validateReferences(input.references, input.mask, input.markup);
  }

  void validateReferences(
    List<ImageAsset> references,
    ImageAsset? maskAsset,
    ImageAsset? markup,
  ) {
    final count = references.length;
    if (count > 0 && referenceField == null)
      throw const FormatException('当前模型端点不接受参考图，请切换编辑端点或移除参考图');
    if (count < minReferences)
      throw FormatException('当前模型至少需要 $minReferences 张参考图');
    if (maxReferences case final max? when count > max)
      throw FormatException('当前模型最多支持 $max 张参考图');
    if (markup != null) throw const FormatException('当前模型不支持标注，请清除编辑图层');
    if (maskAsset case final asset?) {
      if (!mask || count == 0)
        throw const FormatException('当前模型的蒙版需要受支持的参考图编辑模式');
      final first = references.first;
      if (asset.mime != 'image/png' ||
          (first.width != null &&
              asset.width != null &&
              first.width != asset.width) ||
          (first.height != null &&
              asset.height != null &&
              first.height != asset.height)) {
        throw const FormatException('蒙版必须为与首张参考图尺寸相同的 PNG');
      }
    }
    for (final asset in references) {
      validateReference(asset.bytes, asset.mime);
    }
  }

  void validateReference(int bytes, String mime) {
    if (maxReferenceMb case final max? when bytes > max * 1024 * 1024) {
      throw FormatException('当前模型单张参考图不能超过 $max MB');
    }
    if (referenceMimes case final supported?
        when !supported.contains(mime.toLowerCase())) {
      throw const FormatException('当前模型的参考图仅支持 JPEG、PNG 或 WebP');
    }
  }

  Map<String, dynamic> extensionParams(GenerationParams params, String size) {
    final payload = <String, dynamic>{};
    for (final field in extraFields) {
      final raw = params.extra[field.key];
      if (raw == null && !requiredExtra.contains(field.key)) continue;
      if (field.key == 'resolution' &&
          mask &&
          (!ratios.contains(size) || raw == 'auto'))
        continue;
      if ((raw == null && field.defaultValue == null) ||
          (requiredExtra.contains(field.key) &&
              raw is String &&
              raw.trim().isEmpty)) {
        throw FormatException('请填写${field.label}');
      }
      try {
        final value = field.validateValue(raw);
        if (integerExtra.contains(field.key) &&
            value is num &&
            value != value.roundToDouble()) {
          throw FormatException('${field.label}需为整数');
        }
        if (field.key.startsWith('model_params.')) {
          final nested = payload.putIfAbsent(
            'model_params',
            () => <String, dynamic>{},
          ) as Map<String, dynamic>;
          nested[field.key.substring('model_params.'.length)] = value;
        } else {
          payload[field.key] = value;
        }
      } on PluginFieldException catch (error) {
        throw FormatException(error.message);
      }
    }
    return payload;
  }
}

const _seedreamWave = AsyncImageRules(
  sizeField: 'aspect_ratio',
  ratios: seedreamRatios,
  qualityField: 'resolution',
  qualities: _seedreamTiers,
  defaultQuality: '1K',
  lowercaseQuality: true,
  formats: _formats,
  backgrounds: _backgrounds,
  sendAutoBackground: true,
  forceTransparentPng: true,
);
const _seedreamWaveEdit = AsyncImageRules(
  referenceField: 'images',
  minReferences: 1,
  maxReferences: 10,
  sizeField: 'aspect_ratio',
  ratios: seedreamRatios,
  qualityField: 'resolution',
  qualities: _seedreamTiers,
  defaultQuality: '1K',
  lowercaseQuality: true,
  formats: _formats,
  backgrounds: _backgrounds,
  sendAutoBackground: true,
  forceTransparentPng: true,
);
const _seedreamEvo = AsyncImageRules(
  referenceField: 'image_urls',
  maxReferences: 10,
  maxReferenceMb: 30,
  sizeField: 'size',
  ratios: seedreamEvoRatios,
  pixelSize: 'seedream',
  qualityField: 'quality',
  qualities: _seedreamTiers,
  defaultQuality: '1K',
  formats: _formats,
  backgrounds: _backgrounds,
  sendAutoBackground: true,
  forceTransparentPng: true,
);
const _bananaWave = AsyncImageRules(
  referenceField: 'images',
  minReferences: 1,
  maxReferences: 14,
  sizeField: 'aspect_ratio',
  ratios: _bananaRatios,
  qualityField: 'resolution',
  qualities: _bananaTiers,
  lowercaseQuality: true,
  formats: _formats,
  extraFields: [
    PluginField(key: 'enable_web_search', label: '网页搜索', type: 'bool'),
    PluginField(key: 'enable_image_search', label: '图片搜索', type: 'bool'),
  ],
);
const _bananaEvo = AsyncImageRules(
  referenceField: 'image_urls',
  maxReferences: 14,
  maxReferenceMb: 20,
  referenceMimes: _referenceMimes,
  sizeField: 'size',
  ratios: _bananaRatios,
  qualityField: 'quality',
  qualities: _bananaTiers,
  extraFields: [
    PluginField(
      key: 'model_params.web_search',
      label: '网页搜索（另计费）',
      type: 'bool',
    ),
    PluginField(
      key: 'model_params.image_search',
      label: '图片搜索（另计费）',
      type: 'bool',
    ),
    PluginField(
      key: 'model_params.thinking_level',
      label: '思考级别',
      type: 'select',
      options: ['auto', 'min', 'high'],
    ),
  ],
);
const _fluxWave = AsyncImageRules(
  referenceField: 'images',
  minReferences: 1,
  maxReferences: 3,
  sizeField: 'size',
  pixelSize: 'flux',
  extraFields: [PluginField(key: 'seed', label: '随机种子', type: 'number')],
  integerExtra: {'seed'},
);
const _gptEvo = AsyncImageRules(
  referenceField: 'image_urls',
  maxReferences: 16,
  maxReferenceMb: 50,
  referenceMimes: _referenceMimes,
  sizeField: 'size',
  ratios: seedreamRatios,
  pixelSize: 'gpt',
  qualityField: 'quality',
  qualities: ['low', 'medium', 'high'],
  formats: ['png', 'jpeg', 'webp'],
  backgrounds: _backgrounds,
  mask: true,
  extraFields: [
    PluginField(
      key: 'resolution',
      label: '分辨率（选择比例后生效）',
      type: 'select',
      options: ['auto', '1K', '2K', '4K'],
    ),
  ],
);

AsyncImageRules asyncImageRules(
  ApiProtocol protocol,
  String model, {
  Object? waveSchema,
}) {
  if (protocol == ApiProtocol.wavespeed) {
    return switch (model.trim()) {
      'bytedance/seedream-v5.5' => _seedreamWave,
      'bytedance/seedream-v5.5/edit' => _seedreamWaveEdit,
      'google/nano-banana-2/edit' => _bananaWave,
      'wavespeed-ai/flux-2-pro/edit' => _fluxWave,
      'bytedance/seedream-v5.5/layer-decomposition' => const AsyncImageRules(
        unsupported: true,
      ),
      _ =>
        waveSchema is Map
            ? _waveRules(waveSchema)
            : const AsyncImageRules(confirmed: false, referenceField: 'images'),
    };
  }
  return switch (model.trim()) {
    'doubao-seedream-5.5' => _seedreamEvo,
    'gemini-3.1-flash-image-preview' => _bananaEvo,
    'gpt-image-2' => _gptEvo,
    _ => const AsyncImageRules(confirmed: false, referenceField: 'image_urls'),
  };
}

AsyncImageRules rulesForProvider(
  ProviderConfig provider, {
  Object? waveSchema,
}) => asyncImageRules(
  provider.protocol,
  provider.imageModel,
  waveSchema: waveSchema ?? provider.pluginConfig[waveImageSchemaKey],
);

const waveImageTypes = {
  'text-to-image',
  'image-to-image',
  'image-editing',
  'image-edit',
};

Map<String, dynamic>? waveImageSchema(Map item) {
  final id = item['model_id'];
  final api = item['api_schema'];
  if (id is! String || api is! Map || !waveImageTypes.contains(item['type']))
    return null;
  final endpoints = api['api_schemas'];
  if (endpoints is! List) return null;
  // 只使用当前模型的常规生成端点。目录中的 server 不参与认证请求。
  for (final endpoint in endpoints) {
    if (endpoint is Map &&
        endpoint['type'] == 'model_run' &&
        endpoint['method'] == 'POST' &&
        endpoint['api_path'] == '/api/v3/$id' &&
        endpoint['request_schema'] is Map) {
      return Map<String, dynamic>.from(endpoint['request_schema'] as Map);
    }
  }
  return null;
}

AsyncImageRules _waveRules(Map schema) {
  final properties = schema['properties'];
  final rawRequired = schema['required'];
  if (properties is! Map || (rawRequired != null && rawRequired is! List)) {
    return const AsyncImageRules(confirmed: false, referenceField: 'images');
  }
  final required = (rawRequired as List? ?? const [])
      .whereType<String>()
      .toSet();
  List<String> options(String key) {
    final property = properties[key];
    final values = property is Map ? property['enum'] : null;
    return values is List
        ? values.whereType<String>().where((v) => v != 'auto').toSet().toList()
        : const [];
  }

  final images = properties['images'];
  final items = images is Map ? images['items'] : null;
  final hasImages =
      images is Map &&
      images['type'] == 'array' &&
      items is Map &&
      items['type'] == 'string';
  final ratios = options('aspect_ratio')
      .where((v) => RegExp(r'^[1-9]\d{0,2}:[1-9]\d{0,2}$').hasMatch(v))
      .toList();
  final sizes = options('size');
  final resolutions = options('resolution');
  final formats = options('output_format')
      .where({'png', 'jpeg', 'webp'}.contains)
      .toList();
  final background = options('background')
      .where(_backgrounds.contains)
      .toList();
  final sizeField = ratios.isNotEmpty
      ? 'aspect_ratio'
      : sizes.isNotEmpty
      ? 'size'
      : null;
  final covered = {
    if (properties['prompt'] is Map && properties['prompt']['type'] == 'string')
      'prompt',
    if (hasImages) 'images',
    if (sizeField != null) sizeField,
    if (resolutions.isNotEmpty) 'resolution',
    if (formats.isNotEmpty) 'output_format',
  };
  final reserved = {
    'prompt',
    'images',
    'image',
    'mask',
    'mask_url',
    'n',
    'model',
    'aspect_ratio',
    'size',
    'output_format',
    'background',
    'resolution',
    'enable_sync_mode',
    'enable_base64_output',
    'webhook',
  };
  final extras = <PluginField>[];
  final integers = <String>{};
  for (final entry in properties.entries) {
    final key = entry.key;
    final property = entry.value;
    if (key is! String ||
        reserved.contains(key) ||
        key.startsWith('model_params.') ||
        property is! Map) {
      continue;
    }
    final values = options(key);
    final type = switch (property['type']) {
      'number' || 'integer' when property['enum'] == null => 'number',
      'boolean' => 'bool',
      'string' when values.isNotEmpty => 'select',
      'string' when property['enum'] == null && property['format'] == null =>
        'text',
      _ => null,
    };
    if (type == null ||
        (type == 'select' &&
            values.length != (property['enum'] as List).length))
      continue;
    final field = PluginField(
      key: key,
      label: key,
      type: type,
      options: type == 'select' ? values : const [],
      defaultValue: property['default'],
      min: type == 'number' && property['minimum'] is num
          ? property['minimum'] as num
          : null,
      max: type == 'number' && property['maximum'] is num
          ? property['maximum'] as num
          : null,
    );
    if (field.validate() != null) continue;
    extras.add(field);
    covered.add(key);
    if (property['type'] == 'integer') integers.add(key);
  }
  // 缺少必填字段的映射时，避免把不完整的请求送给收费端点。
  if (!covered.contains('prompt') ||
      !covered.containsAll(required) ||
      properties.containsKey('image') ||
      properties.containsKey('mask')) {
    return const AsyncImageRules(unsupported: true);
  }
  final min = hasImages && images['minItems'] is int
      ? images['minItems'] as int
      : 0;
  final max = hasImages && images['maxItems'] is int
      ? images['maxItems'] as int
      : null;
  final defaultResolution = properties['resolution'] is Map
      ? properties['resolution']['default']
      : null;
  return AsyncImageRules(
    confirmed: properties.keys.every(covered.contains),
    requiresPrompt: required.contains('prompt'),
    referenceField: hasImages ? 'images' : null,
    minReferences: required.contains('images') && min < 1 ? 1 : min,
    maxReferences: max,
    sizeField: sizeField,
    requiredSize: required.contains(sizeField),
    requiredQuality: required.contains('resolution'),
    ratios: ratios,
    sizeValues: ratios.isEmpty ? sizes : const [],
    qualityField: resolutions.isEmpty ? null : 'resolution',
    qualities: resolutions,
    defaultQuality: resolutions.contains(defaultResolution)
        ? defaultResolution as String
        : 'auto',
    formats: formats,
    backgrounds: background,
    extraFields: extras,
    requiredExtra: required.intersection(
      extras.map((field) => field.key).toSet(),
    ),
    integerExtra: integers,
  );
}
