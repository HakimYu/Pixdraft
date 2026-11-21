import 'package:flutter/material.dart';

/// 模型仍为单个 ID；回车确认的自定义 ID 会加入本页候选。
class ModelInput extends StatefulWidget {
  const ModelInput({super.key, required this.fieldKey, required this.controller,
    required this.label, required this.models, required this.onConfirmed});

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final List<String> models;
  final ValueChanged<String> onConfirmed;

  @override
  State<ModelInput> createState() => _ModelInputState();
}

class _ModelInputState extends State<ModelInput> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _confirm(String value) {
    final id = value.trim();
    if (id.isEmpty) return;
    widget.controller.value = TextEditingValue(text: id, selection: TextSelection.collapsed(offset: id.length));
    widget.onConfirmed(id);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
    textEditingController: widget.controller,
    focusNode: _focus,
    optionsBuilder: (value) {
      final query = value.text.trim().toLowerCase();
      return widget.models.where((id) => id.toLowerCase().contains(query));
    },
    onSelected: _confirm,
    fieldViewBuilder: (context, controller, focus, onSubmitted) => TextFormField(
      key: widget.fieldKey,
      controller: controller,
      focusNode: focus,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(labelText: widget.label, helperText: '输入搜索候选，回车确认或添加自定义模型', helperMaxLines: 3),
      validator: (value) => value == null || value.trim().isEmpty ? '模型 ID 不能为空' : null,
      onFieldSubmitted: (_) => _confirm(controller.text),
    ),
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: options.length,
              itemBuilder: (context, index) {
                final id = options.elementAt(index);
                return ListTile(title: Text(id), onTap: () => onSelected(id));
              },
            ),
          ),
        ),
      ),
    ),
  );
}
