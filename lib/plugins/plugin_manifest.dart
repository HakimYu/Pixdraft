import 'plugin_contract.dart';

/// 宿主支持的动态插件 API 版本；清单版本不合即拒绝安装。
const int pluginApiVersion = 1;

/// 内置插件版本，与内置扩展 ID 一一对应。
const String builtinPluginVersion = '1.0.0';

/// 不允许被动态插件占用的内置插件 ID。
const Set<String> builtinPluginIds = {
  'builtin.providers',
  'builtin.local-tools',
};


/// 内置扩展已占用的 ID：动态插件不得声明，避免用更高版本号接管内置实现。
const Set<String> builtinProviderExtensionIds = {
  'images',
  'responses',
  'wavespeed',
  'evolink',
};
const Set<String> builtinProcessorExtensionIds = {
  'local.resize',
  'local.watermark',
};
const Set<String> builtinToolExtensionIds = {'tool.watermark', 'tool.resize'};

const int pluginMaxPackageBytes = 16 * 1024 * 1024;
const int pluginMaxFiles = 100;
const int pluginMaxUnpackedBytes = 32 * 1024 * 1024;
const int pluginMaxEntryBytes = 8 * 1024 * 1024;

/// 插件包/清单校验失败；消息可直接展示给用户。
class PluginException implements Exception {
  const PluginException(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _pluginIdPattern = RegExp(r'^[a-z][a-z0-9_-]*(\.[a-z0-9_-]+)+$');
final RegExp _functionPattern = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
final RegExp _versionPattern = RegExp(
  r'^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$',
);
final RegExp _hostPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$',
);
final RegExp _fileNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$');

/// 声明式域名授权：脚本只能请求这些主机，凭据由宿主注入。
class PluginPermissions {
  const PluginPermissions({this.credentials = const {}, this.image = true});
  final Set<String> credentials;
  final bool image;

  Map<String, dynamic> toJson() => {
    'credentials': credentials.toList()..sort(),
    'image': image,
  };
}

class PluginProviderSpec {
  const PluginProviderSpec({
    required this.id,
    required this.name,
    required this.planFunction,
    required this.interpretFunction,
    this.defaultBaseUrl = '',
    this.defaultModel = '',
    this.fields = const [],
    this.capabilities = const GenerationCapabilities(),
  });
  final String id,
      name,
      planFunction,
      interpretFunction,
      defaultBaseUrl,
      defaultModel;
  final List<PluginField> fields;
  final GenerationCapabilities capabilities;

  ProviderDescriptor descriptor(String pluginId, String version) =>
      ProviderDescriptor(
        id: id,
        pluginId: pluginId,
        version: version,
        name: name,
        defaultBaseUrl: defaultBaseUrl,
        defaultModel: defaultModel,
        fields: fields,
      );
}

class PluginProcessorSpec {
  const PluginProcessorSpec({
    required this.id,
    required this.name,
    required this.processFunction,
    this.fields = const [],
  });
  final String id, name, processFunction;
  final List<PluginField> fields;

  ProcessorDescriptor descriptor(String pluginId, String version) =>
      ProcessorDescriptor(
        id: id,
        pluginId: pluginId,
        version: version,
        name: name,
        fields: fields,
      );
}

class PluginToolSpec {
  const PluginToolSpec({
    required this.id,
    required this.name,
    required this.processorId,
    this.fields = const [],
  });
  final String id, name, processorId;
  final List<PluginField> fields;

  ToolDescriptor descriptor(String pluginId, String version) => ToolDescriptor(
    id: id,
    pluginId: pluginId,
    version: version,
    name: name,
    processorId: processorId,
    fields: fields,
  );
}

/// 解析并静态校验 `plugin.json`；任何可疑字段都失败而不是猜测。
class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.entry,
    this.apiVersion = pluginApiVersion,
    this.providers = const [],
    this.processors = const [],
    this.tools = const [],
    this.permissions = const PluginPermissions(),
  });
  final String id, name, version, entry;
  final int apiVersion;
  final List<PluginProviderSpec> providers;
  final List<PluginProcessorSpec> processors;
  final List<PluginToolSpec> tools;
  final PluginPermissions permissions;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'apiVersion': apiVersion,
    'entry': entry,
    'permissions': permissions.toJson(),
    'providers': [
      for (final spec in providers)
        {
          'id': spec.id,
          'name': spec.name,
          'plan': spec.planFunction,
          'interpret': spec.interpretFunction,
          'defaultBaseUrl': spec.defaultBaseUrl,
          'defaultModel': spec.defaultModel,
          'fields': [for (final field in spec.fields) _fieldJson(field)],
        },
    ],
    'processors': [
      for (final spec in processors)
        {
          'id': spec.id,
          'name': spec.name,
          'process': spec.processFunction,
          'fields': [for (final field in spec.fields) _fieldJson(field)],
        },
    ],
    'tools': [
      for (final spec in tools)
        {
          'id': spec.id,
          'name': spec.name,
          'processorId': spec.processorId,
          'fields': [for (final field in spec.fields) _fieldJson(field)],
        },
    ],
  };

  static Map<String, dynamic> _fieldJson(PluginField field) => {
    'key': field.key,
    'label': field.label,
    'type': field.type,
    if (field.defaultValue != null) 'defaultValue': field.defaultValue,
    if (field.options.isNotEmpty) 'options': field.options,
    if (field.min != null) 'min': field.min,
    if (field.max != null) 'max': field.max,
  };

  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    final id = _string(json['id'], 'id');
    if (!_pluginIdPattern.hasMatch(id)) {
      throw const PluginException('插件 ID 需为小写点分名称，例如 com.example.upscale');
    }
    if (builtinPluginIds.contains(id)) {
      throw PluginException('插件 ID「$id」为内置保留 ID');
    }
    final name = _string(json['name'], 'name');
    final version = _string(json['version'], 'version');
    if (!_versionPattern.hasMatch(version)) {
      throw const PluginException('版本需为 x.y.z 数字格式');
    }
    final apiVersion = json['apiVersion'];
    if (apiVersion is! int || apiVersion != pluginApiVersion) {
      throw PluginException(
        '插件 API 版本需为 $pluginApiVersion，实际为 ${apiVersion ?? '缺失'}',
      );
    }
    final entry = _string(json['entry'], 'entry');
    if (!_fileNamePattern.hasMatch(entry) ||
        entry.contains('..') ||
        entry.startsWith('/') ||
        !entry.endsWith('.js')) {
      throw const PluginException('入口文件需为包内 .js 相对路径');
    }
    final permissions = _permissions(json['permissions']);
    final providers = _list(json['providers']).map(_provider).toList();
    final processors = _list(json['processors']).map(_processor).toList();
    final tools = _list(json['tools']).map(_tool).toList();
    if (providers.isEmpty && processors.isEmpty && tools.isEmpty) {
      throw const PluginException('插件至少需声明一个 provider、processor 或 tool');
    }
    final ids = <String>{};
    for (final id in [
      for (final p in providers) p.id,
      for (final p in processors) p.id,
      for (final t in tools) t.id,
    ]) {
      if (!ids.add(id)) throw PluginException('扩展 ID「$id」重复声明');
    }
    for (final spec in providers) {
      if (builtinProviderExtensionIds.contains(spec.id)) {
        throw PluginException('适配器「${spec.id}」属于内置插件，动态插件不能声明');
      }
    }
    for (final spec in processors) {
      if (builtinProcessorExtensionIds.contains(spec.id)) {
        throw PluginException('处理器「${spec.id}」属于内置插件，动态插件不能声明');
      }
    }
    for (final spec in tools) {
      if (builtinToolExtensionIds.contains(spec.id)) {
        throw PluginException('工具「${spec.id}」属于内置插件，动态插件不能声明');
      }
    }
    final processorIds = {for (final processor in processors) processor.id};
    for (final tool in tools) {
      if (!processorIds.contains(tool.processorId)) {
        throw PluginException('工具「${tool.id}」引用了不存在的处理器「${tool.processorId}」');
      }
    }
    final functions = <String>{
      for (final p in providers) ...[p.planFunction, p.interpretFunction],
      for (final p in processors) p.processFunction,
    };
    for (final function in functions) {
      if (!_functionPattern.hasMatch(function)) {
        throw PluginException('脚本函数名「$function」不合法');
      }
    }
    return PluginManifest(
      id: id,
      name: name,
      version: version,
      entry: entry,
      apiVersion: apiVersion,
      providers: providers,
      processors: processors,
      tools: tools,
      permissions: permissions,
    );
  }

  static String _string(Object? value, String key) {
    if (value is! String || value.trim().isEmpty) {
      throw PluginException('清单字段 $key 需为非空字符串');
    }
    if (value.length > 128) throw PluginException('清单字段 $key 过长');
    return value.trim();
  }

  static List<Map<String, dynamic>> _list(Object? value) {
    if (value == null) return const [];
    if (value is! List) throw const PluginException('清单扩展声明需为数组');
    return [for (final item in value) _object(item)];
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map) throw const PluginException('清单扩展声明需为对象');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static PluginPermissions _permissions(Object? value) {
    if (value == null) return const PluginPermissions();
    final json = _object(value);
    final credentials = <String>{};
    final raw = json['credentials'];
    if (raw != null) {
      if (raw is! List) {
        throw const PluginException('permissions.credentials 需为域名字符串数组');
      }
      for (final host in raw) {
        if (host is! String) {
          throw const PluginException('permissions.credentials 需为域名字符串数组');
        }
        final normalized = host.trim().toLowerCase();
        if (!_hostPattern.hasMatch(normalized) ||
            normalized.contains('/') ||
            normalized.contains(':') ||
            normalized.contains('*')) {
          throw PluginException('授权域名「$host」不合法，需为不含通配符与端口的小写主机名');
        }
        credentials.add(normalized);
      }
    }
    final image = json['image'];
    if (image != null && image is! bool) {
      throw const PluginException('permissions.image 需为布尔值');
    }
    return PluginPermissions(
      credentials: credentials,
      image: image as bool? ?? true,
    );
  }

  static PluginProviderSpec _provider(Object? value) {
    final json = _object(value);
    final capabilities = _capabilities(json['capabilities']);
    final fields = _fields(json['fields']);
    final baseUrl = json['defaultBaseUrl'];
    if (baseUrl != null && baseUrl is! String) {
      throw const PluginException('defaultBaseUrl 需为字符串');
    }
    if (baseUrl is String && baseUrl.isNotEmpty) {
      final uri = Uri.tryParse(baseUrl);
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const PluginException('defaultBaseUrl 需为不含凭据与查询的地址');
      }
    }
    return PluginProviderSpec(
      id: _string(json['id'], 'providers[].id'),
      name: _string(json['name'], 'providers[].name'),
      planFunction: _optional(json['plan'], 'plan'),
      interpretFunction: _optional(json['interpret'], 'interpret'),
      defaultBaseUrl: (baseUrl as String?)?.trim() ?? '',
      defaultModel: (json['defaultModel'] as String?)?.trim() ?? '',
      fields: fields,
      capabilities: capabilities,
    );
  }

  static PluginProcessorSpec _processor(Object? value) {
    final json = _object(value);
    return PluginProcessorSpec(
      id: _string(json['id'], 'processors[].id'),
      name: _string(json['name'], 'processors[].name'),
      processFunction: _optional(json['process'], 'process'),
      fields: _fields(json['fields']),
    );
  }

  static PluginToolSpec _tool(Object? value) {
    final json = _object(value);
    return PluginToolSpec(
      id: _string(json['id'], 'tools[].id'),
      name: _string(json['name'], 'tools[].name'),
      processorId: _string(json['processorId'], 'tools[].processorId'),
      fields: _fields(json['fields']),
    );
  }

  static String _optional(Object? value, String fallback) {
    if (value == null) return fallback;
    if (value is! String || value.trim().isEmpty) {
      throw PluginException('函数名需为非空字符串（缺省用 $fallback）');
    }
    return value.trim();
  }

  static List<PluginField> _fields(Object? value) {
    final fields = [
      for (final item
          in value == null
              ? const []
              : (value is List
                    ? value
                    : throw const PluginException('fields 需为数组')))
        _field(item),
    ];
    final error = validatePluginFields(fields);
    if (error != null) throw PluginException(error);
    return fields;
  }

  static PluginField _field(Object? value) {
    final json = _object(value);
    final type = (json['type'] as String?) ?? 'text';
    final options = json['options'];
    if (options != null && options is! List) {
      throw const PluginException('字段 options 需为字符串数组');
    }
    final min = json['min'], max = json['max'];
    if (min != null && min is! num || max != null && max is! num) {
      throw const PluginException('字段 min/max 需为数字');
    }
    return PluginField(
      key: _string(json['key'], 'fields[].key'),
      label: _string(json['label'], 'fields[].label'),
      type: type,
      defaultValue: json['defaultValue'],
      options: options == null
          ? const []
          : [for (final option in options as List) option.toString()],
      min: min as num?,
      max: max as num?,
    );
  }

  static GenerationCapabilities _capabilities(Object? value) {
    if (value == null) return const GenerationCapabilities();
    final json = _object(value);
    List<String> strings(String key, List<String> fallback) {
      final raw = json[key];
      if (raw == null) return fallback;
      if (raw is! List || raw.any((item) => item is! String)) {
        throw PluginException('capabilities.$key 需为字符串数组');
      }
      return [for (final item in raw.cast<String>()) item.trim()]
          .where((item) => item.isNotEmpty)
          .toList();
    }

    bool flag(String key, bool fallback) {
      final raw = json[key];
      if (raw == null) return fallback;
      if (raw is! bool) throw PluginException('capabilities.$key 需为布尔值');
      return raw;
    }

    final maxReferences = json['maxReferences'];
    if (maxReferences != null && maxReferences is! int) {
      throw const PluginException('capabilities.maxReferences 需为整数');
    }
    final capabilities = GenerationCapabilities(
      maxReferences: maxReferences as int? ?? 16,
      supportsMask: flag('supportsMask', false),
      supportsMarkup: flag('supportsMarkup', false),
      supportsPreview: flag('supportsPreview', false),
      supportsFileInput: flag('supportsFileInput', false),
      usesResponseModel: flag('usesResponseModel', false),
      supportsCustomSize: flag('supportsCustomSize', true),
      qualities: strings('qualities', const ['auto', 'low', 'medium', 'high']),
      formats: strings('formats', const ['png', 'jpeg', 'webp', 'gif', 'svg']),
      sizes: strings('sizes', const []),
      extraFields: _fields(json['extraFields']),
    );
    final error = capabilities.validate();
    if (error != null) throw PluginException(error);
    return capabilities;
  }
}
