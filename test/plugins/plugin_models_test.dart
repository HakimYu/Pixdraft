import 'package:flutter_test/flutter_test.dart';
import 'package:image_gen/models/models.dart';

void main() {
  Map<String, dynamic> legacyProvider([Map<String, dynamic> extra = const {}]) => {
        'id': 'p1',
        'name': '旧配置',
        'baseUrl': 'https://api.example.com/v1',
        'imageModel': 'gpt-image-1',
        ...extra,
      };

  test('旧 JSON 没有 adapterId 时按 protocol 名称推导', () {
    final provider = ProviderConfig.fromJson(legacyProvider({'protocol': 'wavespeed'}));
    expect(provider.protocol, ApiProtocol.wavespeed);
    expect(provider.adapterId, 'wavespeed');
    expect(provider.adapterVersion, isNull);
    expect(provider.pluginConfig, isEmpty);
  });

  test('未知 protocol 名称保留为 adapterId，枚举回落旧默认值', () {
    final provider = ProviderConfig.fromJson(legacyProvider({'protocol': 'brand-new'}));
    expect(provider.protocol, ApiProtocol.images, reason: '旧代码读取时仍能工作');
    expect(provider.adapterId, 'brand-new', reason: '执行侧据此拒绝，而不是悄悄生图');
    expect(ProviderConfig.fromJson(provider.toJson()).adapterId, 'brand-new', reason: '往返不丢原始 ID');
  });

  test('adapterId / 版本 / 插件配置往返保留', () {
    final provider = ProviderConfig.fromJson(legacyProvider({
      'protocol': 'images',
      'adapterId': 'com.example.upscale',
      'adapterVersion': '2.3.4',
      'pluginConfig': {'steps': 8, 'tile': true},
    }));
    final round = ProviderConfig.fromJson(provider.toJson());
    expect(round.adapterId, 'com.example.upscale');
    expect(round.adapterVersion, '2.3.4');
    expect(round.pluginConfig, {'steps': 8, 'tile': true});
    expect(round.protocol, ApiProtocol.images);
  });

  test('空 adapterId 明确报错，不静默回退', () {
    final provider = ProviderConfig.fromJson(legacyProvider({'adapterId': '  '}));
    expect(provider.adapterId, 'images');
    expect(provider.validate(), isNull);
    const broken = ProviderConfig(id: 'p', name: '测试', baseUrl: 'https://api.example.com/v1', adapterId: ' ');
    expect(broken.validate(), '适配器 ID 不能为空');
  });

  test('GenerationInput 的处理步骤往返，copyWith 不清空 mask/markup', () {
    final input = GenerationInput(
      taskId: 't1',
      provider: ProviderConfig.fromJson(legacyProvider()),
      prompt: '猫',
      params: const GenerationParams(extra: {'guidance': 4.5}),
      mask: const ImageAsset(id: 'm', path: 'assets/m.png', mime: 'image/png', hash: 'h', bytes: 1),
      markup: const ImageAsset(id: 'k', path: 'assets/k.png', mime: 'image/png', hash: 'h', bytes: 1),
      preprocessors: const [ProcessingStep(pluginId: 'builtin.local-tools', version: '1.0.0', processorId: 'local.resize', params: {'width': 512})],
      postprocessors: const [ProcessingStep(pluginId: 'com.example.stamp', version: '1.0.0', processorId: 'example.stamp', params: {'text': '示例'})],
    );

    final round = GenerationInput.fromJson(input.toJson());
    expect(round.preprocessors.single.processorId, 'local.resize');
    expect(round.postprocessors.single.params, {'text': '示例'});
    expect(round.params.extra, {'guidance': 4.5});

    final copy = round.copyWith(params: const GenerationParams(count: 2));
    expect(copy.mask?.id, 'm');
    expect(copy.markup?.id, 'k');
    expect(copy.preprocessors, hasLength(1));
    expect(copy.prompt, '猫');
    expect(copy.provider.adapterId, 'images');
  });

  test('缺少新字段的旧任务 JSON 可读取', () {
    final input = GenerationInput.fromJson({
      'taskId': 'old',
      'provider': legacyProvider(),
      'prompt': '旧任务',
      'params': {'count': 2},
    });
    expect(input.preprocessors, isEmpty);
    expect(input.postprocessors, isEmpty);
    expect(input.params.count, 2);
    expect(input.params.extra, isEmpty);
  });
}