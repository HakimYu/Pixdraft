import 'package:flutter/material.dart';

import '../../plugins/plugin_contract.dart';

/// 按插件声明的字段校验当前值；返回中文错误信息，未通过时不能执行。
String? validatePluginFieldValues(List<PluginField> fields, Map<String, dynamic> values) {
  final keys = <String>{};
  for (final field in fields) {
    if (!keys.add(field.key)) return '插件字段名重复：${field.key}';
    try {
      field.validateValue(values[field.key]);
    } on PluginFieldException catch (error) {
      return error.message;
    }
  }
  return null;
}

String _number(num value) => value == value.roundToDouble() ? value.toInt().toString() : value.toString();

/// 字段初始值：内置默认值优先，其次按类型取安全默认。
Map<String, dynamic> pluginFieldDefaults(List<PluginField> fields) {
  final defaults = <String, dynamic>{
    for (final field in fields)
      field.key: switch (field.type) {
        'bool' => field.defaultValue is bool && field.defaultValue as bool,
        'select' => field.defaultValue is String && field.options.contains(field.defaultValue) ? field.defaultValue : field.options.firstOrNull,
        'number' => field.defaultValue is num ? field.defaultValue : null,
        _ => field.defaultValue is String ? field.defaultValue : null,
      },
  };
  defaults.removeWhere((_, value) => value == null);
  return defaults;
}

/// 只按声明渲染插件字段，不加载任何插件自带界面代码。
class PluginFieldsForm extends StatefulWidget {
  const PluginFieldsForm({super.key, required this.fields, this.initial = const {}, required this.onChanged, this.enabled = true});
  final List<PluginField> fields;
  final Map<String, dynamic> initial;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;

  @override
  State<PluginFieldsForm> createState() => _PluginFieldsFormState();
}

class _PluginFieldsFormState extends State<PluginFieldsForm> {
  final Map<String, dynamic> _values = {};
  final _controllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _values.addAll(pluginFieldDefaults(widget.fields));
    _values.addAll(widget.initial);
    for (final field in widget.fields) {
      if (field.type == 'text' || field.type == 'number') {
        _controllers[field.key] = TextEditingController(text: _values[field.key]?.toString() ?? '');
      }
    }
    widget.onChanged(Map.of(_values));
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _update(String key, Object? value) {
    setState(() {
      if (value == null || (value is String && value.isEmpty)) {
        _values.remove(key);
      } else {
        _values[key] = value;
      }
    });
    widget.onChanged(Map.of(_values));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final field in widget.fields) ...[
        switch (field.type) {
          'bool' => SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(field.label), value: _values[field.key] == true, onChanged: widget.enabled ? (value) => _update(field.key, value) : null),
          'select' => DropdownButtonFormField<String>(
            initialValue: _values[field.key] as String?,
            decoration: InputDecoration(labelText: field.label, border: const OutlineInputBorder()),
            items: [for (final option in field.options) DropdownMenuItem(value: option, child: Text(option))],
            onChanged: widget.enabled ? (value) => _update(field.key, value) : null,
          ),
          _ => TextField(
            controller: _controllers[field.key],
            enabled: widget.enabled,
            keyboardType: field.type == 'number' ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
            decoration: InputDecoration(labelText: field.label, helperText: field.type == 'number' && (field.min != null || field.max != null) ? '范围 ${field.min == null ? '不限' : _number(field.min!)}–${field.max == null ? '不限' : _number(field.max!)}' : null, border: const OutlineInputBorder()),
            onChanged: (text) => _update(field.key, field.type == 'number' ? (_parseNumber(text) ?? text) : text),
          ),
        },
        const SizedBox(height: 16),
      ],
    ],
  );
}

num? _parseNumber(String text) {
  final value = num.tryParse(text.trim());
  if (value == null) return null;
  return value == value.roundToDouble() ? value.toInt() : value;
}