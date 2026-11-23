import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../studio_image.dart';
import 'editor_export.dart';
import 'editor_geometry.dart';

/// 编辑结果：同一时间最多一种图层，另一个为 null。
class ImageEditResult {
  const ImageEditResult({this.mask, this.markup});

  final ImageAsset? mask, markup;
}

class ImageEditorPage extends StatefulWidget {
  const ImageEditorPage({
    super.key,
    required this.store,
    required this.source,
    this.initialMask,
    this.initialMarkup,
    this.maskOnly = false,
  });

  final StudioStore store;
  final ImageAsset source;
  final ImageAsset? initialMask, initialMarkup;
  final bool maskOnly;

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> {
  late final String _draftKey = 'editor:${widget.source.id}${widget.maskOnly ? ':mask' : ''}';
  EditorHistory? _history;
  ImageAsset? _existingMask, _existingMarkup;
  Size? _pixels;
  String? _error;
  EditorTool _tool = EditorTool.mask;
  bool _loading = true, _saving = false;
  Offset? _maskAnchor;
  Rect? _pendingMask;
  List<Offset>? _pendingStroke;
  static const _strokePointLimit = 4000;
  bool _pointLimitNotified = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!canEditAsset(widget.source)) {
      setState(() {
        _loading = false;
        _error = unsupportedMessage(widget.source.mime);
      });
      return;
    }
    Size pixels;
    try {
      final bytes = await widget.store.readAsset(widget.source);
      pixels = await readImageSize(bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '无法读取源图，请重新选择图片';
      });
      return;
    }
    if (pixels.width * pixels.height > editPixelLimit) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = oversizedMessage(pixels.width.round(), pixels.height.round());
      });
      return;
    }
    Map<String, dynamic>? saved;
    try {
      saved = await widget.store.setting(_draftKey);
    } catch (_) {
      saved = null;
    }
    final draft = draftFromJson(saved) ?? const EditorDraft.empty();
    if (!mounted) return;
    setState(() {
      _pixels = pixels;
      _history = EditorHistory(initial: draft);
      if (draft.isEmpty) {
        _existingMask = widget.initialMask;
        _existingMarkup = widget.initialMarkup;
      }
      _loading = false;
    });
  }

  EditorDraft get _shown {
    final current = _history?.current ?? const EditorDraft.empty();
    if (_pendingMask != null) return EditorDraft.withMask(_pendingMask!);
    if (_pendingStroke != null) {
      return EditorDraft(strokes: [...current.strokes, _pendingStroke!]);
    }
    return current;
  }

  void _begin(Offset local, Rect box) {
    final point = normalizedPoint(local, box);
    if (point == null) return;
    setState(() {
      _pointLimitNotified = false;
      if (_tool == EditorTool.mask) {
        _maskAnchor = point;
        _pendingMask = Rect.fromPoints(point, point);
        _pendingStroke = null;
      } else {
        _pendingStroke = [point];
        _pendingMask = null;
        _maskAnchor = null;
      }
    });
  }

  void _extend(Offset local, Rect box) {
    if (box.width <= 0 || box.height <= 0) return;
    final point = clampNormalized(
      Offset(
        (local.dx - box.left) / box.width,
        (local.dy - box.top) / box.height,
      ),
    );
    if (_pendingStroke != null && _pendingStroke!.length >= _strokePointLimit) {
      if (!_pointLimitNotified) {
        _pointLimitNotified = true;
        _notify('单笔最多 $_strokePointLimit 个点，已停止记录本笔后续轨迹；抬指后可另起一笔');
      }
      return;
    }
    setState(() {
      final anchor = _maskAnchor;
      if (anchor != null) {
        _pendingMask = normalizedRect(anchor, point);
      } else if (_pendingStroke != null) {
        final last = _pendingStroke!.last;
        if ((last - point).distanceSquared > 0.000002) {
          _pendingStroke = [..._pendingStroke!, point];
        }
      }
    });
  }

  void _finish() {
    final mask = _pendingMask;
    final stroke = _pendingStroke;
    final history = _history;
    final pixels = _pixels;
    if (history == null || pixels == null) {
      _cancelGesture();
      return;
    }
    if (mask != null &&
        (mask.width * pixels.width < 2 || mask.height * pixels.height < 2)) {
      _cancelGesture();
      _notify('选区太小，请拖动绘制');
      return;
    }
    if (mask != null) {
      history.commit(EditorDraft.withMask(mask));
    } else if (stroke != null && stroke.isNotEmpty) {
      history.commit(
        EditorDraft(strokes: [...history.current.strokes, stroke]),
      );
    }
    // 新绘制替换已载入的旧图层，保证两类图层互斥。
    _existingMask = null;
    _existingMarkup = null;
    setState(_cancelGesture);
    _persistDraft();
  }

  void _cancelGesture() {
    _maskAnchor = null;
    _pendingMask = null;
    _pendingStroke = null;
  }

  void _undo() {
    if (_history?.undo() ?? false) {
      setState(() {});
      _persistDraft();
    }
  }

  void _redo() {
    if (_history?.redo() ?? false) {
      setState(() {});
      _persistDraft();
    }
  }

  void _clear() {
    final history = _history;
    if (history == null) return;
    if (history.current.isEmpty &&
        _existingMask == null &&
        _existingMarkup == null) {
      return;
    }
    setState(() {
      history.commit(const EditorDraft.empty());
      _existingMask = null;
      _existingMarkup = null;
      _cancelGesture();
    });
    _persistDraft();
  }

  void _persistDraft() {
    final draft = _history?.current ?? const EditorDraft.empty();
    unawaited(
      widget.store
          .saveSetting(_draftKey, draft.toJson())
          .catchError((Object _) {}),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final history = _history;
    final pixels = _pixels;
    if (history == null || pixels == null) return;
    final draft = history.current;
    final existingMask = _existingMask;
    final existingMarkup = _existingMarkup;
    if (draft.isEmpty && (existingMask != null || existingMarkup != null)) {
      Navigator.of(context)
          .pop(ImageEditResult(mask: existingMask, markup: existingMarkup));
      return;
    }
    if (draft.isEmpty) {
      _notify('请先绘制矩形蒙版或红线标注');
      return;
    }
    setState(() => _saving = true);
    try {
      final width = pixels.width.round();
      final height = pixels.height.round();
      final bytes = draft.mask != null
          ? await encodeMask(width, height, draft.mask!)
          : await encodeMarkup(width, height, draft.strokes);
      final asset = await widget.store.saveAsset(bytes, 'image/png');
      try {
        await widget.store.saveSetting(
          _draftKey,
          const EditorDraft.empty().toJson(),
        );
      } catch (_) {
        // 草稿清理失败不影响已导出的图片。
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        ImageEditResult(
          mask: draft.mask != null ? asset : null,
          markup: draft.mask == null ? asset : null,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _notify(_saveError(error));
    }
  }

  String _saveError(Object error) {
    if (error is FormatException) return error.message;
    if (error is StateError) return error.message;
    return '保存失败，请检查存储空间后重试';
  }

  void _notify(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _status(EditorDraft draft) {
    if (draft.mask != null) return '矩形蒙版：透明区域允许重绘';
    if (draft.strokes.isNotEmpty) return '红线标注：${draft.strokes.length} 笔';
    if (_existingMask != null) return '已载入现有蒙版';
    if (_existingMarkup != null) return '已载入现有标注';
    return '尚未绘制';
  }

  String? get _existingNote {
    if (_existingMask != null && _existingMarkup != null) {
      return '已载入现有蒙版和标注；开始绘制会替换它们';
    }
    if (_existingMask != null) return '已载入现有蒙版；开始绘制会替换它';
    if (_existingMarkup != null) return '已载入现有标注；开始绘制会替换它';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _notify('正在保存，请稍候');
      },
      child: CallbackShortcuts(
        bindings: {
          for (final meta in [false, true]) ...{
            SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: !meta,
              meta: meta,
            ): () {
              if (!_saving && _history?.canUndo == true) _undo();
            },
            SingleActivator(
              LogicalKeyboardKey.keyZ,
              control: !meta,
              meta: meta,
              shift: true,
            ): () {
              if (!_saving && _history?.canRedo == true) _redo();
            },
            SingleActivator(
              LogicalKeyboardKey.keyS,
              control: !meta,
              meta: meta,
            ): () {
              if (!_saving && _history != null) unawaited(_save());
            },
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('编辑图片'),
              actions: _history == null
                  ? null
                  : [
                      IconButton(
                        key: const ValueKey('editorUndo'),
                        tooltip: '撤销',
                        icon: const Icon(Icons.undo),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _saving || !_history!.canUndo ? null : _undo,
                      ),
                      IconButton(
                        key: const ValueKey('editorRedo'),
                        tooltip: '重做',
                        icon: const Icon(Icons.redo),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _saving || !_history!.canRedo ? null : _redo,
                      ),
                      IconButton(
                        key: const ValueKey('editorClear'),
                        tooltip: '清空',
                        icon: const Icon(Icons.delete_outline),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed:
                            _saving ||
                                (_history!.current.isEmpty &&
                                    _existingMask == null &&
                                    _existingMarkup == null)
                            ? null
                            : _clear,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 4, right: 12),
                        child: FilledButton(
                          key: const ValueKey('editorSave'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(72, 48),
                          ),
                          onPressed: _saving ? null : _save,
                          child: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('保存'),
                        ),
                      ),
                    ],
            ),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _ErrorView(
                    message: _error!,
                    onBack: () => Navigator.pop(context),
                  )
                : _buildEditor(),
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    final pixels = _pixels!;
    final draft = _shown;
    final note = _existingNote;
    final canvas = Padding(
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final box = fitContain(
            Size(constraints.maxWidth, constraints.maxHeight),
            pixels,
          );
          return GestureDetector(
            key: const ValueKey('editorCanvas'),
            behavior: HitTestBehavior.opaque,
            onPanStart: _saving
                ? null
                : (details) => _begin(details.localPosition, box),
            onPanUpdate: _saving
                ? null
                : (details) => _extend(details.localPosition, box),
            onPanEnd: _saving ? null : (_) => _finish(),
            onPanCancel: _saving ? null : _cancelGesture,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fromRect(
                  rect: box,
                  child: StudioImage(
                    store: widget.store,
                    asset: widget.source,
                    fit: BoxFit.fill,
                    cacheWidth: math.min(
                      1600,
                      math.max(1, pixels.width.round()),
                    ),
                  ),
                ),
                if (_existingMarkup != null && draft.isEmpty)
                  Positioned.fromRect(
                    rect: box,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: 0.85,
                        child: StudioImage(
                          store: widget.store,
                          asset: _existingMarkup!,
                          fit: BoxFit.fill,
                          cacheWidth: math.min(
                            1600,
                            math.max(1, pixels.width.round()),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fromRect(
                  rect: box,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _EditorPainter(
                        draft: draft,
                        imageWidth: pixels.width.round(),
                      ),
                    ),
                  ),
                ),
                if (draft.isEmpty && note == null && _existingMarkup == null)
                  Center(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Text(
                            _tool == EditorTool.mask
                                ? '在图片上拖动，画出矩形蒙版'
                                : '在图片上自由画红线',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    final tools = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null) _ExistingLayerNote(message: note),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_status(draft)} · 源图 ${pixels.width.round()}×${pixels.height.round()}',
                  key: const ValueKey('editorStatus'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _toolButton(
                      EditorTool.mask,
                      '矩形蒙版',
                      Icons.crop_free,
                      'editorToolMask',
                    ),
                    if (!widget.maskOnly)
                    _toolButton(
                      EditorTool.markup,
                      '红线标注',
                      Icons.gesture,
                      'editorToolMarkup',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '画布按原图等比适配（contain），单指绘制；暂不支持缩放，避免缩放后误画。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 760;
          return Flex(
            direction: wide ? Axis.horizontal : Axis.vertical,
            children: [
              Expanded(child: canvas),
              if (wide) const VerticalDivider(width: 1),
              SizedBox(
                width: wide ? 256 : constraints.maxWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: wide
                        ? constraints.maxHeight
                        : constraints.maxHeight * .48,
                  ),
                  child: tools,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _toolButton(EditorTool tool, String label, IconData icon, String key) {
    final selected = _tool == tool;
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    final onPressed = _saving ? null : () => setState(() => _tool = tool);
    return selected
        ? FilledButton.icon(
            key: ValueKey(key),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          )
        : OutlinedButton.icon(
            key: ValueKey(key),
            style: style,
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          );
  }
}

class _ExistingLayerNote extends StatelessWidget {
  const _ExistingLayerNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              key: const ValueKey('editorError'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
              onPressed: onBack,
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditorPainter extends CustomPainter {
  _EditorPainter({required this.draft, required this.imageWidth});

  final EditorDraft draft;
  final int imageWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final mask = draft.mask;
    if (mask != null) {
      final rect = Rect.fromLTRB(
        mask.left * size.width,
        mask.top * size.height,
        mask.right * size.width,
        mask.bottom * size.height,
      );
      canvas.drawRect(rect, Paint()..color = const Color(0x553D8BFF));
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xFF1E6CFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (draft.strokes.isEmpty || size.width <= 0) return;
    final paint = Paint()
      ..color = const Color(0xFFFF0000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(
        1.5,
        markupStrokeWidth(imageWidth) * size.width / imageWidth,
      )
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final points in draft.strokes) {
      if (points.isEmpty) continue;
      if (points.length == 1) {
        canvas.drawCircle(
          Offset(points.first.dx * size.width, points.first.dy * size.height),
          paint.strokeWidth / 2,
          Paint()..color = const Color(0xFFFF0000),
        );
        continue;
      }
      final path = Path()
        ..moveTo(points.first.dx * size.width, points.first.dy * size.height);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx * size.width, point.dy * size.height);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_EditorPainter oldDelegate) =>
      oldDelegate.draft != draft || oldDelegate.imageWidth != imageWidth;
}
