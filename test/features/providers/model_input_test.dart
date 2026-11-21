import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/providers/model_input.dart';

void main() {
  testWidgets('模型候选按输入过滤、点选；回车添加自定义 ID', (tester) async {
    final controller = TextEditingController();
    final models = ['gpt-image-1', 'gpt-4.1'];
    String? confirmed;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) => ModelInput(
        fieldKey: const ValueKey('model'), controller: controller,
        label: '模型', models: models,
        onConfirmed: (value) => setState(() {
          confirmed = value;
          if (!models.contains(value)) models.add(value);
        }),
      ),
    ))));
    final field = find.byKey(const ValueKey('model'));
    await tester.enterText(field, 'image');
    await tester.pumpAndSettle();
    expect(find.text('gpt-image-1'), findsOneWidget);
    final option = find.widgetWithText(ListTile, 'gpt-image-1');
    expect(tester.getSize(option).width, tester.getSize(field).width);
    expect(find.text('gpt-4.1'), findsNothing);
    await tester.tap(find.text('gpt-image-1'));
    await tester.pumpAndSettle();
    expect(controller.text, 'gpt-image-1');
    expect(confirmed, 'gpt-image-1');
    await tester.enterText(field, ' custom-image ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.text, 'custom-image');
    expect(confirmed, 'custom-image');
    expect(models, contains('custom-image'));
    await tester.enterText(field, 'custom');
    await tester.pumpAndSettle();
    expect(find.text('custom-image'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
