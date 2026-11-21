import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/create/size_selector.dart';

void main() {
  test('所有比例档位符合现有尺寸边界', () {
    for (final ratio in [...commonRatios, ...extraRatios]) {
      for (final k in [1, 2, 4]) {
        final parts = sizeForRatio(ratio, k).split('x').map(int.parse).toList();
        expect(parts.every((v) => v % 16 == 0 && v <= 3840), isTrue);
        expect(parts[0] * parts[1], inInclusiveRange(655360, 8294400));
      }
    }
    expect(sizeForRatio('4:3', 1), '1024x768');
    expect(sizeForRatio('4:3', 2), '2048x1536');
  });
  testWidgets('先比例再档位，更多比例折叠，按钮含示意框，自定义可输入', (tester) async {
    var size = 'auto';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: StatefulBuilder(
      builder: (context, setState) => SizeSelector(size: size, onChanged: (value) => setState(() => size = value)),
    )))));
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '1K')).onSelected, isNull);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '4:3')).avatar, isNotNull);
    await tester.tap(find.text('4:3'));
    await tester.pumpAndSettle();
    expect(size, '1024x768');
    await tester.tap(find.text('2K'));
    await tester.pumpAndSettle();
    expect(size, '2048x1536');
    await tester.tap(find.text('更多比例'));
    await tester.pumpAndSettle();
    expect(find.text('21:9'), findsOneWidget);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.first, '1200');
    await tester.enterText(fields.last, '900');
    await tester.pumpAndSettle();
    expect(size, '1200x900');
    await tester.enterText(fields.first, '');
    await tester.pumpAndSettle();
    expect(size, '');
    expect(find.text('请输入有效的正整数宽高'), findsOneWidget);
  });
}
