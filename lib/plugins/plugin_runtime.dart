import 'dart:async';

import 'package:jsf/jsf.dart';

import '../models/models.dart';
import 'local_processing.dart';
import 'plugin_contract.dart';
import 'plugin_manifest.dart';

/// 单次脚本调用的外墙钟预算：由 QuickJS 中断处理器硬中断，不依赖 Future.timeout。
const Duration pluginScriptTimeout = Duration(seconds: 5);
const int pluginScriptMemoryLimitBytes = 64 * 1024 * 1024;
const int pluginScriptMaxStackBytes = 2 * 1024 * 1024;

/// 脚本调用失败；[timedOut] 表示被中断处理器硬中断。
class PluginScriptException implements Exception {
  const PluginScriptException(this.message, {this.timedOut = false});
  final String message;
  final bool timedOut;
  @override
  String toString() => message;
}

/// 一个已编译的插件脚本：无网络、无文件、无 Dart 句柄，只有纯函数。
class PluginScript {
  PluginScript._(this._runtime, this.manifest);
  final JsRuntime _runtime;
  final PluginManifest manifest;

  /// 编译入口脚本。语法错误立即失败，不把坏脚本留到调用时。
  static PluginScript compile({
    required PluginManifest manifest,
    required String source,
  }) {
    late final JsRuntime runtime;
    try {
      runtime = JsRuntime(
        options: const JsRuntimeOptions(
          memoryLimitBytes: pluginScriptMemoryLimitBytes,
          maxStackSizeBytes: pluginScriptMaxStackBytes,
          timeout: pluginScriptTimeout,
        ),
      );
    } on JsException catch (error) {
      throw PluginScriptException('初始化 JS 运行时失败：${error.message}');
    }
    try {
      runtime.eval(source, filename: manifest.entry);
    } on JsException catch (error) {
      runtime.dispose();
      throw PluginScriptException(_describe(error, manifest.entry));
    } on Object catch (error) {
      runtime.dispose();
      throw PluginScriptException('加载 ${manifest.entry} 失败：$error');
    }
    return PluginScript._(runtime, manifest);
  }

  /// 调用清单里声明的函数，参数与返回值只走 JSON 兼容类型。
  Object? call(String function, Map<String, dynamic> payload) {
    try {
      return _runtime.call(function, [payload]);
    } on JsException catch (error) {
      throw PluginScriptException(
        _describe(error, function),
        timedOut: _interrupted(error),
      );
    } on Object catch (error) {
      throw PluginScriptException('脚本函数 $function 失败：$error');
    }
  }

  /// QuickJS 中断处理器到点后以 InternalError: interrupted 结束执行。
  static bool _interrupted(JsException error) =>
      error.name == 'InternalError' && error.message.contains('interrupted');

  static String _describe(JsException error, String where) {
    final message = error.message;
    if (_interrupted(error)) {
      return '脚本 $where 执行超过 ${pluginScriptTimeout.inMilliseconds}ms，已强制中断';
    }
    return '脚本 $where 抛错：$message';
  }

  void dispose() => _runtime.dispose();
}

/// 把脚本返回值规整成对象；类型不符时给出可读错误。
Map<String, dynamic> pluginScriptObject(Object? value, String where) {
  if (value is Map) return Map<String, dynamic>.from(value);
  throw PluginScriptException('$where 需返回对象');
}

/// 分辨率/宽高只接受有限正整数，避免坏参数流进 HTTP 请求。
int? pluginScriptInt(Object? value) => value is int && value > 0
    ? value
    : (value is num && value.isFinite && value > 0 ? value.toInt() : null);

/// 处理器脚本的操作描述，交给本地处理模块执行。
class PluginOperation {
  const PluginOperation(this.operation, this.params);
  final String operation;
  final Map<String, dynamic> params;

  static List<PluginOperation> parse(Object? value, String where) {
    final json = pluginScriptObject(value, where);
    final operations = json['operations'];
    if (operations is! List || operations.isEmpty) {
      throw PluginScriptException('$where.operations 需为非空数组');
    }
    if (operations.length > 8) {
      throw const PluginScriptException('单次脚本最多 8 个图片操作');
    }
    return [
      for (final item in operations)
        if (item is Map && item['operation'] is String)
          PluginOperation(
            item['operation'] as String,
            item['params'] is Map
                ? Map<String, dynamic>.from(item['params'] as Map)
                : const {},
          )
        else
          throw const PluginScriptException('图片操作需为 {operation, params} 对象'),
    ];
  }
}

/// 处理器脚本：只描述操作，不接触像素；实际计算由本地处理模块完成。
class PluginScriptProcessor implements ImageProcessorExtension {
  PluginScriptProcessor({
    required this.descriptor,
    required this.function,
    required this._script,
  });
  @override
  final ProcessorDescriptor descriptor;
  final String function;
  final PluginScript _script;

  @override
  Future<ImageAsset> process(
    ImageAsset image,
    Map<String, dynamic> params,
    ProcessingContext context,
  ) async {
    context.checkCancelled();
    final bytes = await context.readImage(image);
    final output = _script.call(function, {
      'params': params,
      'image': {
        'id': image.id,
        'mime': image.mime,
        'width': image.width,
        'height': image.height,
        'bytes': bytes.length,
      },
    });
    context.checkCancelled();
    final operations = PluginOperation.parse(output, 'process');
    var current = bytes;
    for (final operation in operations) {
      context.checkCancelled();
      current = await applyLocalImageOperation(
        current,
        operation.operation,
        operation.params,
      );
    }
    context.checkCancelled();
    return context.saveImage(current, 'image/png');
  }
}
