import 'dart:math' as math;
import 'dart:ui';

/// 编辑页当前使用的工具。两种编辑层互斥：同一时间只保留一种。
enum EditorTool { mask, markup }

/// 编辑草稿只保存归一化向量数据（0–1），与源图像素尺寸解耦。
class EditorDraft {
  const EditorDraft({this.mask, this.strokes = const []});
  const EditorDraft.empty() : mask = null, strokes = const [];

  /// 矩形蒙版；用透明区域表达可重绘部分。
  final Rect? mask;

  /// 自由红线，每条线是一串归一化坐标点。
  final List<List<Offset>> strokes;

  bool get isEmpty => mask == null && strokes.isEmpty;

  /// 绘制矩形时清空标注，保证两个图层互斥。
  factory EditorDraft.withMask(Rect mask) =>
      EditorDraft(mask: mask, strokes: const []);

  Map<String, dynamic> toJson() => {
    'mask': mask == null
        ? null
        : [mask!.left, mask!.top, mask!.right, mask!.bottom],
    'strokes': [
      for (final stroke in strokes)
        [for (final point in stroke) ...[point.dx, point.dy]],
    ],
  };

  @override
  bool operator ==(Object other) =>
      other is EditorDraft &&
      other.mask == mask &&
      _sameStrokes(other.strokes, strokes);

  @override
  int get hashCode =>
      Object.hash(mask, Object.hashAll(strokes.map(Object.hashAll)));

  static bool _sameStrokes(List<List<Offset>> a, List<List<Offset>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }
}

/// 宽松解析历史草稿：无效字段被忽略，全部无效时返回 null。
EditorDraft? draftFromJson(Object? value) {
  if (value is! Map) return null;
  Rect? mask;
  final rawMask = value['mask'];
  if (rawMask is List && rawMask.length == 4) {
    final values = [for (final item in rawMask) item is num ? item.toDouble() : null];
    if (values.every((item) => item != null && item.isFinite)) {
      final rect = Rect.fromLTRB(values[0]!, values[1]!, values[2]!, values[3]!);
      final clamped = _clampRect(rect);
      if (clamped.width > 0 && clamped.height > 0) mask = clamped;
    }
  }
  final strokes = <List<Offset>>[];
  final rawStrokes = value['strokes'];
  if (rawStrokes is List) {
    for (final rawStroke in rawStrokes) {
      if (rawStroke is! List || rawStroke.length < 2 || rawStroke.length.isOdd) {
        continue;
      }
      final points = <Offset>[];
      var valid = true;
      for (var i = 0; i < rawStroke.length; i += 2) {
        final x = rawStroke[i], y = rawStroke[i + 1];
        if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
          valid = false;
          break;
        }
        points.add(clampNormalized(Offset(x.toDouble(), y.toDouble())));
      }
      if (valid && points.isNotEmpty) strokes.add(points);
    }
  }
  if (mask == null && strokes.isEmpty) return null;
  return EditorDraft(mask: mask, strokes: strokes);
}

Rect _clampRect(Rect rect) {
  final left = rect.left.clamp(0.0, 1.0);
  final top = rect.top.clamp(0.0, 1.0);
  final right = rect.right.clamp(0.0, 1.0);
  final bottom = rect.bottom.clamp(0.0, 1.0);
  return Rect.fromLTRB(
    math.min(left, right),
    math.min(top, bottom),
    math.max(left, right),
    math.max(top, bottom),
  );
}

/// 撤销/重做栈，保存提交前后的草稿快照。
class EditorHistory {
  EditorHistory({EditorDraft initial = const EditorDraft.empty(), this.maxEntries = 50})
    : _current = initial;

  final int maxEntries;
  final List<EditorDraft> _undo = [];
  final List<EditorDraft> _redo = [];
  EditorDraft _current;

  EditorDraft get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void commit(EditorDraft next) {
    if (next == _current) return;
    _undo.add(_current);
    if (_undo.length > maxEntries) _undo.removeAt(0);
    _redo.clear();
    _current = next;
  }

  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_current);
    _current = _undo.removeLast();
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    _undo.add(_current);
    _current = _redo.removeLast();
    return true;
  }
}

/// 等比适配（contain）后的图片显示区域，留白居中。
Rect fitContain(Size viewport, Size image) {
  if (viewport.width <= 0 ||
      viewport.height <= 0 ||
      image.width <= 0 ||
      image.height <= 0) {
    return Rect.zero;
  }
  final scale = math.min(
    viewport.width / image.width,
    viewport.height / image.height,
  );
  final width = image.width * scale;
  final height = image.height * scale;
  return Rect.fromLTWH(
    (viewport.width - width) / 2,
    (viewport.height - height) / 2,
    width,
    height,
  );
}

Offset clampNormalized(Offset point) =>
    Offset(point.dx.clamp(0.0, 1.0), point.dy.clamp(0.0, 1.0));

/// 显示坐标转归一化坐标；显示区域外返回 null，避免把误触算进选区。
Offset? normalizedPoint(Offset local, Rect box) {
  if (box.width <= 0 || box.height <= 0) return null;
  if (local.dx < box.left ||
      local.dy < box.top ||
      local.dx > box.right ||
      local.dy > box.bottom) {
    return null;
  }
  return clampNormalized(
    Offset((local.dx - box.left) / box.width, (local.dy - box.top) / box.height),
  );
}

Rect normalizedRect(Offset start, Offset end) =>
    Rect.fromPoints(clampNormalized(start), clampNormalized(end));

Rect pixelRect(Rect normalized, int width, int height) => Rect.fromLTRB(
  normalized.left * width,
  normalized.top * height,
  normalized.right * width,
  normalized.bottom * height,
);

/// 导出红线宽度：随源图宽度缩放，最小 2 像素。
double markupStrokeWidth(int imageWidth) => math.max(2.0, imageWidth / 240.0);
