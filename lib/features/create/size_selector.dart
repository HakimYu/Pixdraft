import 'dart:math';

import 'package:flutter/material.dart';

import '../../api/params.dart';

const commonRatios = ['1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3'];
const extraRatios = [
  '5:4',
  '4:5',
  '7:5',
  '5:7',
  '16:10',
  '10:16',
  '2:1',
  '1:2',
  '21:9',
  '9:21',
  '3:1',
  '1:3',
];

String sizeForRatio(String ratio, int k) {
  final parts = ratio.split(':').map(int.parse).toList();
  final edge = k * 1024;
  final scale = edge / max(parts[0], parts[1]);
  return normalizeSize(
    '${(parts[0] * scale).round()}x${(parts[1] * scale).round()}',
  );
}

class SizeSelector extends StatefulWidget {
  const SizeSelector({
    super.key,
    required this.size,
    required this.onChanged,
    this.supportedRatios,
    this.allowCustomPixels = false,
    this.presetSizes = const [],
  });
  final List<String>? supportedRatios;
  final bool allowCustomPixels;
  final List<String> presetSizes;
  final String size;
  final ValueChanged<String> onChanged;
  @override
  State<SizeSelector> createState() => _SizeSelectorState();
}

class _SizeSelectorState extends State<SizeSelector> {
  String _ratio = 'auto';
  int _k = 1;
  final _width = TextEditingController(text: '1024');
  final _height = TextEditingController(text: '1024');
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(SizeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.size.isNotEmpty &&
        oldWidget.size != widget.size &&
        widget.size != _selectedSize)
      _restore();
  }

  String get _selectedSize => _ratio == 'custom'
      ? '${_width.text}x${_height.text}'
      : widget.supportedRatios != null || _ratio == 'auto'
      ? _ratio
      : sizeForRatio(_ratio, _k);
  void _restore() {
    if (widget.supportedRatios != null &&
        (widget.size == 'auto' ||
            widget.supportedRatios!.contains(widget.size) ||
            widget.presetSizes.contains(widget.size))) {
      _ratio = widget.size;
      return;
    }
    _ratio = widget.size == 'auto' ? 'auto' : 'custom';
    for (final ratio in [...commonRatios, ...extraRatios]) {
      for (final k in [1, 2, 4]) {
        if (sizeForRatio(ratio, k) == widget.size) {
          _ratio = ratio;
          _k = k;
          return;
        }
      }
    }
    final parts = widget.size.split(RegExp(r'[xX×*]'));
    _width.text = parts.length == 2 ? parts[0] : '1024';
    _height.text = parts.length == 2 ? parts[1] : '1024';
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _choose(String ratio) {
    setState(() {
      _ratio = ratio;
      _error = null;
    });
    if (ratio == 'custom') {
      _custom();
    } else {
      widget.onChanged(_selectedSize);
    }
  }

  void _custom() {
    final w = int.tryParse(_width.text.trim());
    final h = int.tryParse(_height.text.trim());
    if (w == null || h == null || w <= 0 || h <= 0) {
      widget.onChanged('');
      setState(() => _error = '请输入有效的正整数宽高');
      return;
    }
    setState(() => _error = null);
    widget.onChanged('${w}x$h');
  }

  Widget _miniature(String ratio) {
    if (ratio == 'auto')
      return const Icon(Icons.auto_awesome_outlined, size: 18);
    if (ratio == 'custom') return const Icon(Icons.crop_free, size: 18);
    final parts = ratio.split(':').map(int.parse).toList();
    final scale = 22 / max(parts[0], parts[1]);
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Container(
          width: parts[0] * scale,
          height: parts[1] * scale,
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.onSurface,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _ratios(List<String> ratios) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final ratio in ratios)
        ChoiceChip(
          avatar: _miniature(ratio),
          showCheckmark: false,
          label: Text(
            ratio == 'auto'
                ? '自动'
                : ratio == 'custom'
                ? '自定义'
                : ratio,
          ),
          selected: _ratio == ratio,
          onSelected: (_) => _choose(ratio),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final supported = widget.supportedRatios;
    final additional = supported == null
        ? extraRatios
        : supported.where((ratio) => !commonRatios.contains(ratio)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('画面比例', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _ratios([
          'auto',
          ...commonRatios.where((ratio) => supported?.contains(ratio) ?? true),
          if (supported == null || widget.allowCustomPixels) 'custom',
        ]),
        if (additional.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('更多比例'),
            initiallyExpanded: additional.contains(_ratio),
            children: [_ratios(additional), const SizedBox(height: 12)],
          ),
        if (supported == null || widget.allowCustomPixels) ...[
          if (_ratio == 'custom') ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _width,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '宽（像素）'),
                    onChanged: (_) => _custom(),
                  ),
                ),
                const Padding(padding: EdgeInsets.all(12), child: Text('×')),
                Expanded(
                  child: TextField(
                    controller: _height,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '高（像素）'),
                    onChanged: (_) => _custom(),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ] else if (supported == null) ...[
            const Text('分辨率档位'),
            Wrap(
              spacing: 8,
              children: [
                for (final k in [1, 2, 4])
                  ChoiceChip(
                    label: Text('${k}K'),
                    selected: _ratio != 'auto' && _k == k,
                    onSelected: _ratio == 'auto'
                        ? null
                        : (_) {
                            setState(() => _k = k);
                            widget.onChanged(_selectedSize);
                          },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (supported == null)
            Text(
              _ratio == 'auto'
                  ? '自动比例和分辨率由模型决定；指定 K 数请先选择比例。'
                  : '实际请求：${normalizeSize(widget.size)} 像素（按接口尺寸限制调整）',
            ),
        ],
        if (widget.presetSizes.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final size in widget.presetSizes)
                ChoiceChip(
                  label: Text(size),
                  selected: size == _ratio,
                  onSelected: (_) => _choose(size),
                ),
            ],
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
