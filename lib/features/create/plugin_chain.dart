import 'package:flutter/material.dart';

import '../../api/params.dart';
import '../../models/models.dart';
import '../../plugins/plugin_contract.dart';
import '../plugins/plugin_fields_form.dart';

/// 质量选项跟随插件能力声明；没有能力信息时沿用内置供应商的旧选项。
List<String> qualityOptionsFor(
  GenerationCapabilities? capabilities, {
  required bool asyncProtocol,
  required String model,
}) {
  final declared = capabilities?.qualities ?? const <String>[];
  if (declared.isNotEmpty) return [...declared];
  return asyncProtocol
      ? const ['auto', '1K', '1.5K', '2K']
      : [
          'auto',
          'low',
          'medium',
          'high',
          if (isGptImage25Model(model)) ...['xhigh', 'max'],
        ];
}

List<String> formatOptionsFor(
  GenerationCapabilities? capabilities, {
  required bool asyncProtocol,
}) {
  final declared = capabilities?.formats ?? const <String>[];
  if (declared.isNotEmpty) return [...declared];
  return asyncProtocol
      ? const ['png', 'jpeg']
      : const ['png', 'jpeg', 'webp', 'gif', 'svg'];
}

int referenceLimitFor(
  GenerationCapabilities? capabilities, {
  required bool asyncProtocol,
}) => capabilities?.maxReferences ?? (asyncProtocol ? 10 : 16);

/// 把字段表单的值写回步骤；未声明的字段不会进入任务快照。
ProcessingStep withStepParams(
  ProcessingStep step,
  Map<String, dynamic> params,
) => ProcessingStep(
  pluginId: step.pluginId,
  version: step.version,
  processorId: step.processorId,
  params: Map<String, dynamic>.from(params),
);

/// 步骤标题：优先用已注册处理器名称，插件缺失时退回 processorId。
String describeStep(List<ProcessorDescriptor> processors, ProcessingStep step) {
  for (final processor in processors) {
    if (processor.id == step.processorId && processor.pluginId == step.pluginId)
      return processor.name;
  }
  return step.processorId;
}

ProcessorDescriptor? findProcessor(
  List<ProcessorDescriptor> processors,
  ProcessingStep step,
) {
  for (final processor in processors) {
    if (processor.id == step.processorId &&
        processor.pluginId == step.pluginId &&
        processor.version == step.version)
      return processor;
  }
  return null;
}

/// 显式编排的本地处理链：顺序、参数都由用户决定，生成前/后各一条。
class PluginChainEditor extends StatelessWidget {
  const PluginChainEditor({
    super.key,
    required this.title,
    required this.steps,
    required this.processors,
    required this.onChanged,
    this.hint,
  });
  final String title;
  final List<ProcessingStep> steps;
  final List<ProcessorDescriptor> processors;
  final ValueChanged<List<ProcessingStep>> onChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          TextButton.icon(
            key: ValueKey('add-$title'),
            onPressed: processors.isEmpty ? null : () => _add(context),
            icon: const Icon(Icons.add),
            label: const Text('添加'),
          ),
        ],
      ),
      if (steps.isEmpty && hint != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(hint!, style: Theme.of(context).textTheme.bodySmall),
        ),
      for (var i = 0; i < steps.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ExpansionTile(
            key: ValueKey('step-$title-$i-${steps[i].processorId}'),
            title: Text('${i + 1}. ${describeStep(processors, steps[i])}'),
            subtitle: Text('${steps[i].pluginId}@${steps[i].version}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '上移',
                  onPressed: i == 0 ? null : () => _move(i, i - 1),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: '下移',
                  onPressed: i == steps.length - 1
                      ? null
                      : () => _move(i, i + 1),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  tooltip: '删除步骤',
                  onPressed: () => _remove(i),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            children: [_fields(i)],
          ),
        ),
    ],
  );

  Widget _fields(int index) {
    final step = steps[index];
    final processor = findProcessor(processors, step);
    if (processor == null)
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text(
          '找不到处理器 ${step.processorId}（插件 ${step.pluginId}@${step.version}），生成前请先安装或启用该插件',
        ),
      );
    if (processor.fields.isEmpty)
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text('该步骤没有可调参数'),
      );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: PluginFieldsForm(
        key: ValueKey('fields-$title-$index-${step.processorId}'),
        fields: processor.fields,
        initial: step.params,
        // 字段表单只在自身 initState 里回报一次初始值，这里不能触发重建。
        onChanged: (values) =>
            onChanged([...steps]..[index] = withStepParams(step, values)),
      ),
    );
  }

  void _move(int from, int to) {
    final next = [...steps];
    next.insert(to, next.removeAt(from));
    onChanged(next);
  }

  void _remove(int index) => onChanged([...steps]..removeAt(index));

  Future<void> _add(BuildContext context) async {
    final processor = await showModalBottomSheet<ProcessorDescriptor>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in processors)
              ListTile(
                title: Text(item.name),
                subtitle: Text('${item.pluginId}@${item.version}'),
                onTap: () => Navigator.pop(context, item),
              ),
          ],
        ),
      ),
    );
    if (processor == null) return;
    onChanged([
      ...steps,
      ProcessingStep(
        pluginId: processor.pluginId,
        version: processor.version,
        processorId: processor.id,
        params: pluginFieldDefaults(processor.fields),
      ),
    ]);
  }
}
