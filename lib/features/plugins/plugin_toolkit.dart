import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/local_processing.dart';
import '../../plugins/plugin_contract.dart';

/// 宿主可注入的工具集；缺省由页面从注册表读取内置与插件提供的工具。
typedef PluginToolkitLoader = Future<PluginToolkit> Function(StudioStore store);

class PluginToolkit {
  const PluginToolkit({required this.tools, required this.process, this.dispose});
  final List<ToolDescriptor> tools;
  final Future<ImageAsset> Function(ImageAsset image, ProcessingStep step, {bool Function()? isCancelled}) process;
  final Future<void> Function()? dispose;

  /// 只用随包内置的处理器，不加载任何插件代码。
  static PluginToolkit builtin(StudioStore store) {
    final processors = {for (final processor in createBuiltinProcessors()) processor.descriptor.id: processor};
    return PluginToolkit(
      tools: builtinTools(),
      process: (image, step, {isCancelled}) {
        final processor = processors[step.processorId];
        if (processor == null) throw FormatException('未找到处理器 ${step.processorId}');
        return processor.process(image, step.params, ProcessingContext(readImage: (asset) => store.fileFor(asset).readAsBytes(), saveImage: store.saveAsset, isCancelled: isCancelled));
      },
    );
  }
}