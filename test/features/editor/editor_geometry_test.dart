import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/editor/editor_geometry.dart';

void main() {
  group('fitContain', () {
    test('宽视口时上下留白并水平居中', () {
      final box = fitContain(const Size(200, 100), const Size(100, 100));
      expect(box, const Rect.fromLTWH(50, 0, 100, 100));
    });

    test('高视口时左右留白并垂直居中', () {
      final box = fitContain(const Size(100, 200), const Size(400, 100));
      expect(box, const Rect.fromLTWH(0, 87.5, 100, 25));
    });

    test('视口或图片为空时返回零矩形', () {
      expect(fitContain(Size.zero, const Size(10, 10)), Rect.zero);
      expect(fitContain(const Size(10, 10), Size.zero), Rect.zero);
    });
  });

  group('坐标换算', () {
    const box = Rect.fromLTWH(20, 10, 200, 100);

    test('显示区域中心映射到 0.5', () {
      expect(normalizedPoint(const Offset(120, 60), box), const Offset(.5, .5));
    });

    test('显示区域外返回 null，避免留白误画', () {
      expect(normalizedPoint(const Offset(10, 60), box), isNull);
      expect(normalizedPoint(const Offset(120, 5), box), isNull);
      expect(normalizedPoint(const Offset(230, 60), box), isNull);
    });

    test('反方向拖动仍生成左上到右下的归一化矩形', () {
      final rect = normalizedRect(const Offset(.8, .9), const Offset(.2, .1));
      expect(rect, const Rect.fromLTRB(.2, .1, .8, .9));
    });

    test('归一化矩形映射到源图像素', () {
      expect(
        pixelRect(const Rect.fromLTRB(.25, .5, .75, 1), 400, 200),
        const Rect.fromLTRB(100, 100, 300, 200),
      );
    });

    test('导出线宽随源图宽度变化并有最小值', () {
      expect(markupStrokeWidth(100), 2);
      expect(markupStrokeWidth(2400), 10);
    });
  });

  group('EditorDraft', () {
    test('矩形与标注互斥', () {
      final withStroke = EditorDraft(
        mask: const Rect.fromLTRB(.1, .1, .2, .2),
        strokes: [
          [const Offset(.1, .1)],
        ],
      );
      final maskOnly = EditorDraft.withMask(const Rect.fromLTRB(.2, .2, .4, .4));
      expect(maskOnly.strokes, isEmpty);
      expect(maskOnly.mask, const Rect.fromLTRB(.2, .2, .4, .4));

      final strokeOnly = EditorDraft(
        strokes: [...withStroke.strokes, [const Offset(.3, .3)]],
      );
      expect(strokeOnly.mask, isNull);
      expect(strokeOnly.strokes, hasLength(2));
    });

    test('JSON 往返保留蒙版与多笔标注', () {
      final draft = EditorDraft(
        strokes: [
          [const Offset(0, 0), const Offset(1, 1)],
          [const Offset(.25, .75)],
        ],
      );
      final restored = draftFromJson(draft.toJson());
      expect(restored, draft);
    });

    test('无效草稿被忽略或安全收敛', () {
      expect(draftFromJson(null), isNull);
      expect(draftFromJson('bad'), isNull);
      expect(draftFromJson({'mask': 'bad', 'strokes': 'bad'}), isNull);
      expect(
        draftFromJson({
          'mask': [.1, .2, double.nan, .4],
          'strokes': [
            [1.2, -.5],
            [double.infinity, .5],
            [.1],
          ],
        }),
        const EditorDraft(strokes: [
          [Offset(1, 0)],
        ]),
      );
      expect(
        draftFromJson({
          'mask': [.8, .8, .2, .2],
        })?.mask,
        const Rect.fromLTRB(.2, .2, .8, .8),
      );
    });
  });

  group('EditorHistory', () {
    test('撤销与重做恢复草稿', () {
      final history = EditorHistory();
      final mask = EditorDraft.withMask(const Rect.fromLTRB(.1, .1, .5, .5));
      history.commit(mask);
      expect(history.canUndo, isTrue);
      expect(history.current, mask);

      expect(history.undo(), isTrue);
      expect(history.current, const EditorDraft.empty());
      expect(history.canRedo, isTrue);

      expect(history.redo(), isTrue);
      expect(history.current, mask);
      expect(history.canRedo, isFalse);
    });

    test('新提交清空重做栈，重复提交不产生历史', () {
      final history = EditorHistory();
      final first = EditorDraft.withMask(const Rect.fromLTRB(.1, .1, .3, .3));
      final second = EditorDraft.withMask(const Rect.fromLTRB(.2, .2, .6, .6));
      history.commit(first);
      history.commit(first);
      history.undo();
      history.commit(second);
      expect(history.canRedo, isFalse);
      history.undo();
      expect(history.current, const EditorDraft.empty());
      expect(history.canUndo, isFalse);
    });

    test('历史条数受上限约束，清空可撤销', () {
      final history = EditorHistory(maxEntries: 2);
      for (var i = 0; i < 4; i++) {
        history.commit(
          EditorDraft.withMask(Rect.fromLTRB(0, 0, .1 * (i + 1), .1)),
        );
      }
      expect(history.current.mask, const Rect.fromLTRB(0, 0, .4, .1));
      history.undo();
      history.undo();
      expect(history.undo(), isFalse);

      history.commit(const EditorDraft.empty());
      expect(history.current.isEmpty, isTrue);
      expect(history.undo(), isTrue);
      expect(history.current.isEmpty, isFalse);
    });
  });
}
