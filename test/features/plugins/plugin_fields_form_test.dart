import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/features/plugins/plugin_fields_form.dart';
import 'package:image_gen/plugins/plugin_contract.dart';

const _fields = [
  PluginField(key: 'text', label: '水印文字', defaultValue: '仅供预览'),
  PluginField(key: 'opacity', label: '不透明度', type: 'number', defaultValue: 0.6, min: 0.05, max: 1),
  PluginField(key: 'position', label: '位置', type: 'select', options: ['右下', '居中'], defaultValue: '右下'),
  PluginField(key: 'keep', label: '保持比例', type: 'bool', defaultValue: true),
];

void main() {
  test('默认值覆盖四类字段，校验通过', () {
    final values = pluginFieldDefaults(_fields);
    expect(values, {'text': '仅供预览', 'opacity': 0.6, 'position': '右下', 'keep': true});
    expect(validatePluginFieldValues(_fields, values), isNull);
  });

  test('越界与非法选项被拒绝', () {
    expect(validatePluginFieldValues(_fields, {...pluginFieldDefaults(_fields), 'opacity': 2}), '不透明度 不能大于 1');
    expect(validatePluginFieldValues(_fields, {...pluginFieldDefaults(_fields), 'opacity': 0.01}), '不透明度 不能小于 0.05');
    expect(validatePluginFieldValues(_fields, {...pluginFieldDefaults(_fields), 'position': '左上'}), '位置 需从选项中选择');
    expect(validatePluginFieldValues(_fields, {...pluginFieldDefaults(_fields), 'keep': 'yes'}), '保持比例 需为开关值');
  });

  test('重复字段名不被静默覆盖', () {
    const duplicated = [PluginField(key: 'a', label: '甲'), PluginField(key: 'a', label: '乙')];
    expect(validatePluginFieldValues(duplicated, const {}), contains('重复'));
  });

  testWidgets('按声明渲染并回传归一化参数', (tester) async {
    var values = <String, dynamic>{};
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PluginFieldsForm(fields: _fields, onChanged: (next) => values = next))));
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('保持比例'), findsOneWidget);
    expect(values['position'], '右下');

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(values['keep'], isFalse);

    await tester.enterText(find.byType(TextField).at(1), '0.3');
    await tester.pump();
    expect(values['opacity'], 0.3);
    expect(validatePluginFieldValues(_fields, values), isNull);

    await tester.enterText(find.byType(TextField).at(1), '');
    await tester.pump();
    expect(values.containsKey('opacity'), isFalse);
    expect(validatePluginFieldValues(_fields, values), isNull, reason: '留空即使用字段默认值');
  });
}