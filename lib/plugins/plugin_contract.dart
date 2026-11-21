import 'dart:typed_data';

import '../models/models.dart';

/// 插件字段类型校验失败。
class PluginFieldException implements Exception {
  const PluginFieldException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 宿主允许的字段类型；不执行描述中的任何表达式。
const Set<String> pluginFieldTypes = {'text', 'number', 'select', 'bool'};

/// 宿主渲染参数表单的最小字段描述。
class PluginField {
  const PluginField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
  });
  final String key, label, type;
  final dynamic defaultValue;
  final List<String> options;
  final num? min, max;

  /// 静态校验：字段名、类型、默认值、选项与数值边界。
  String? validate() {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,63}$').hasMatch(key)) {
      return '字段名 $key 不合法';
    }
    if (label.trim().isEmpty) return '字段 $key 缺少名称';
    if (!pluginFieldTypes.contains(type)) return '字段 $key 类型 $type 不受支持';
    if (type == 'select' && options.isEmpty) return '字段 $key 缺少选项';
    if (type != 'select' && options.isNotEmpty) return '字段 $key 的选项仅用于 select';
    if (min != null && !min!.isFinite || max != null && !max!.isFinite) {
      return '字段 $key 数值边界需为有限数';
    }
    if (min != null && max != null && min! > max!) return '字段 $key 数值边界颠倒';
    if (type != 'number' && (min != null || max != null)) {
      return '字段 $key 的数值边界仅用于 number';
    }
    if (defaultValue != null) {
      try {
        validateValue(defaultValue);
      } on PluginFieldException catch (error) {
        return '字段 $key 默认值无效：${error.message}';
      }
    }
    return null;
  }

  /// 校验单值并返回归一化结果；空值返回默认值。
  Object? validateValue(Object? value) {
    final effective = value ?? defaultValue;
    switch (type) {
      case 'text':
        if (effective == null) return '';
        if (effective is! String) throw PluginFieldException('$label 需为文本');
        return effective.length > 8192
            ? throw PluginFieldException('$label 内容过长')
            : effective;
      case 'number':
        final number = effective is num
            ? effective
            : (effective is String ? num.tryParse(effective.trim()) : null);
        if (number == null || !number.isFinite) {
          throw PluginFieldException('$label 需为有限数字');
        }
        if (min != null && number < min!) {
          throw PluginFieldException('$label 不能小于 $min');
        }
        if (max != null && number > max!) {
          throw PluginFieldException('$label 不能大于 $max');
        }
        return number;
      case 'select':
        final text = effective?.toString();
        if (text == null || !options.contains(text)) {
          throw PluginFieldException('$label 需从选项中选择');
        }
        return text;
      case 'bool':
        if (effective is bool) return effective;
        if (effective is String &&
            (effective == 'true' || effective == 'false')) {
          return effective == 'true';
        }
        throw PluginFieldException('$label 需为开关值');
      default:
        throw PluginFieldException('$label 类型不受支持');
    }
  }
}

/// 按字段描述校验并归一化参数表，忽略未声明的扩展键。
/// 字段集合静态校验：逐字段合法且 key 唯一，重复 key 不得被静默覆盖。
String? validatePluginFields(List<PluginField> fields) {
  final seen = <String>{};
  for (final field in fields) {
    final error = field.validate();
    if (error != null) return error;
    if (!seen.add(field.key)) return '字段 ${field.key} 重复声明';
  }
  return null;
}

Map<String, dynamic> validatePluginParams(
  List<PluginField> fields,
  Map<String, dynamic> params,
) {
  final invalid = validatePluginFields(fields);
  if (invalid != null) throw PluginFieldException(invalid);
  final normalized = <String, dynamic>{};
  for (final field in fields) {
    final error = field.validate();
    if (error != null) throw PluginFieldException(error);
    normalized[field.key] = field.validateValue(params[field.key]);
  }
  return normalized;
}

/// 插件声明的能力；UI 与计划校验共用，不根据协议猜。
class GenerationCapabilities {
  const GenerationCapabilities({
    this.maxReferences = 16,
    this.supportsMask = false,
    this.supportsMarkup = false,
    this.supportsPreview = false,
    this.supportsFileInput = false,
    this.usesResponseModel = false,
    this.supportsCustomSize = true,
    this.qualities = const ['auto', 'low', 'medium', 'high'],
    this.formats = const ['png', 'jpeg', 'webp', 'gif', 'svg'],
    this.sizes = const [],
    this.extraFields = const [],
  });
  final int maxReferences;
  final bool supportsMask,
      supportsMarkup,
      supportsPreview,
      supportsFileInput,
      usesResponseModel,
      supportsCustomSize;
  final List<String> qualities, formats, sizes;
  final List<PluginField> extraFields;

  String? validate() {
    if (maxReferences < 0 || maxReferences > 64) return '参考图上限需为 0–64';
    if (qualities.isEmpty || formats.isEmpty) return '质量与格式列表不能为空';
    return validatePluginFields(extraFields);
  }
}

/// 校验并归一化后的有效输入与期望出图数量。
class GenerationPlan {
  const GenerationPlan({
    required this.input,
    required this.expectedCount,
    this.metadata = const {},
  });
  final GenerationInput input;
  final int expectedCount;
  final Map<String, dynamic> metadata;
}

class ProviderDescriptor {
  const ProviderDescriptor({
    required this.id,
    required this.pluginId,
    required this.version,
    required this.name,
    this.defaultBaseUrl = '',
    this.defaultModel = '',
    this.fields = const [],
  });
  final String id, pluginId, version, name, defaultBaseUrl, defaultModel;
  final List<PluginField> fields;
}

class ProcessorDescriptor {
  const ProcessorDescriptor({
    required this.id,
    required this.pluginId,
    required this.version,
    required this.name,
    this.fields = const [],
  });
  final String id, pluginId, version, name;
  final List<PluginField> fields;
}

class ToolDescriptor {
  const ToolDescriptor({
    required this.id,
    required this.pluginId,
    required this.version,
    required this.name,
    required this.processorId,
    this.fields = const [],
  });
  final String id, pluginId, version, name, processorId;
  final List<PluginField> fields;
}

/// 生图提供商扩展；取消只作用于自己发起的任务。
abstract class ProviderExtension implements GenerationClient {
  ProviderDescriptor get descriptor;
  GenerationCapabilities capabilities(
    ProviderConfig provider, {
    bool hasInputImages = false,
  });
  Future<GenerationPlan> plan(GenerationInput input);
  Future<List<String>> discoverModels(ProviderConfig provider, String? apiKey);
}

/// 图片处理扩展；只读写宿主传入的受限上下文。
abstract class ImageProcessorExtension {
  ProcessorDescriptor get descriptor;
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  );
}

/// 处理已取消，不是插件缺陷。
class ProcessingCancelled implements Exception {
  const ProcessingCancelled();
  @override
  String toString() => '处理已取消';
}

/// 处理执行期间的受限资源访问；脚本与插件拿不到 store、路径或数据库。
class ProcessingContext {
  ProcessingContext({
    required this.readImage,
    required this.saveImage,
    this._isCancelled,
  });
  // 契约固定命名参数为 isCancelled，故保留非初始化形参。
  final Future<Uint8List> Function(ImageAsset) readImage;
  final Future<ImageAsset> Function(Uint8List, String) saveImage;
  final bool Function()? _isCancelled;

  void checkCancelled() {
    if (_isCancelled?.call() ?? false) throw const ProcessingCancelled();
  }
}
