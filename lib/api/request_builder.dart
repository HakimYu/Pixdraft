import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'params.dart';

const _compatibilityPrefix = '兼容模式要求：不要改写、重排、总结、翻译、润色或省略下面的“原始提示词”内容。\n'
    '请保留原始提示词中的段落结构、列表、标签、代码块、正向/负向要求、参数描述与措辞重点，并尽量按原文语义直接执行。\n'
    '原始提示词如下：\n\n';

String responsesPrompt(String prompt, {required bool compatibility}) {
  if (!compatibility || prompt.trim().isEmpty) return prompt;
  return '$_compatibilityPrefix$prompt';
}

Uri apiEndpoint(String baseUrl, String endpoint, {required bool allowHttp}) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.host.isEmpty) throw const FormatException('服务地址无效');
  if (uri.scheme != 'https' && !(allowHttp && uri.scheme == 'http')) {
    throw const FormatException('服务地址必须使用 HTTPS，或显式允许明文 HTTP');
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final target = path.isEmpty ? '${uri.origin}/v1/$endpoint' : '${uri.origin}$path/$endpoint';
  final result = Uri.tryParse(target);
  if (result == null) throw const FormatException('服务地址无效');
  return result;
}

String imageDataUrl(Uint8List bytes, String mime) => 'data:$mime;base64,${base64Encode(bytes)}';

DioMediaType mediaTypeFor(String mime) {
  final parts = mime.split('/');
  return DioMediaType(parts.first, parts.length > 1 ? parts.sublist(1).join('/') : 'octet-stream');
}

void appendSharedImageParams(
  Map<String, dynamic> target,
  ResolvedParams params, {
  required int count,
  required bool isEdit,
  required bool stream,
  required int partialImages,
}) {
  if (params.background.isNotEmpty) target['background'] = params.background;
  if (count > 1) target['n'] = count;
  if (isEdit && params.inputFidelity != null) target['input_fidelity'] = params.inputFidelity;
  if (params.format == 'gif') {
    target['frame_count'] = params.gifFrames;
    target['frame_duration_ms'] = params.gifDuration;
  }
  if (params.complexity != null) target['complexity'] = params.complexity;
  if (stream && params.canStream) target['partial_images'] = partialImages.clamp(0, 3);
}

void _appendSharedForm(
  List<MapEntry<String, String>> fields,
  ResolvedParams params, {
  required int count,
  required bool isEdit,
  required bool stream,
  required int partialImages,
}) {
  if (params.background.isNotEmpty) fields.add(MapEntry('background', params.background));
  if (count > 1) fields.add(MapEntry('n', '$count'));
  if (isEdit && params.inputFidelity != null) {
    fields.add(MapEntry('input_fidelity', params.inputFidelity!));
  }
  if (params.format == 'gif') {
    fields.add(MapEntry('frame_count', '${params.gifFrames}'));
    fields.add(MapEntry('frame_duration_ms', '${params.gifDuration}'));
  }
  if (params.complexity != null) fields.add(MapEntry('complexity', params.complexity!));
  if (stream && params.canStream) {
    fields.add(MapEntry('partial_images', '${partialImages.clamp(0, 3)}'));
  }
}

Map<String, dynamic> imagesBody({
  required ProviderConfig provider,
  required String prompt,
  required ResolvedParams params,
  required int count,
  required bool stream,
  required bool edit,
  required List<String> imageUrls,
  String? maskUrl,
  String? markupUrl,
}) {
  final body = <String, dynamic>{
    'model': provider.imageModel.trim(),
    'prompt': prompt,
    'size': params.size,
    'quality': params.quality,
    'output_format': params.format,
    'moderation': params.moderation,
  };
  if (edit) {
    body['images'] = [for (final url in imageUrls) {'image_url': url}];
  }
  if (params.hasCompression) body['output_compression'] = params.compression;
  final safety = provider.safetyIdentifier.trim();
  if (safety.isNotEmpty) body['safety_identifier'] = safety;
  appendSharedImageParams(
    body,
    params,
    count: count,
    isEdit: edit,
    stream: stream,
    partialImages: provider.partialImages,
  );
  if (edit && maskUrl != null) body['mask'] = {'image_url': maskUrl};
  if (edit && markupUrl != null) body['markup'] = {'image_url': markupUrl};
  if (stream) body['stream'] = true;
  return body;
}

FormData imagesForm({
  required ProviderConfig provider,
  required String prompt,
  required ResolvedParams params,
  required int count,
  required bool stream,
  required List<MultipartFile> images,
  MultipartFile? mask,
  MultipartFile? markup,
}) {
  final fields = <MapEntry<String, String>>[
    MapEntry('model', provider.imageModel.trim()),
    MapEntry('prompt', prompt),
    MapEntry('size', params.size),
    MapEntry('quality', params.quality),
    MapEntry('output_format', params.format),
    MapEntry('moderation', params.moderation),
  ];
  if (params.hasCompression) {
    fields.add(MapEntry('output_compression', '${params.compression}'));
  }
  final safety = provider.safetyIdentifier.trim();
  if (safety.isNotEmpty) fields.add(MapEntry('safety_identifier', safety));
  _appendSharedForm(
    fields,
    params,
    count: count,
    isEdit: true,
    stream: stream,
    partialImages: provider.partialImages,
  );
  if (stream) fields.add(const MapEntry('stream', 'true'));

  final form = FormData();
  form.fields.addAll(fields);
  for (final image in images) {
    form.files.add(MapEntry('image[]', image));
  }
  if (mask != null) form.files.add(MapEntry('mask', mask));
  if (markup != null) form.files.add(MapEntry('markup', markup));
  return form;
}

Map<String, dynamic> responsesBody({
  required ProviderConfig provider,
  required String prompt,
  required ResolvedParams params,
  required int count,
  required bool stream,
  required List<Map<String, dynamic>> images,
  Map<String, dynamic>? mask,
  required bool explicitAction,
  required bool forceTool,
}) {
  final model = provider.responseModel.trim();
  final toolModel = provider.toolModel.trim();
  if (model.isEmpty || toolModel.isEmpty) throw const FormatException('模型 ID 不能为空');

  final content = <Map<String, dynamic>>[];
  if (prompt.trim().isNotEmpty) content.add({'type': 'input_text', 'text': prompt});
  content.addAll(images);

  final tool = <String, dynamic>{
    'type': 'image_generation',
    'model': toolModel,
    'size': params.size,
    'quality': params.quality,
    'output_format': params.format,
    'moderation': params.moderation,
  };
  if (params.hasCompression) tool['output_compression'] = params.compression;
  appendSharedImageParams(
    tool,
    params,
    count: count,
    isEdit: images.isNotEmpty,
    stream: stream,
    partialImages: provider.partialImages,
  );
  if (mask != null) tool['input_image_mask'] = mask;
  if (explicitAction) tool['action'] = images.isEmpty ? 'generate' : 'edit';

  final body = <String, dynamic>{
    'model': model,
    'input': [
      {'role': 'user', 'content': content},
    ],
    'tools': [tool],
  };
  final safety = provider.safetyIdentifier.trim();
  if (safety.isNotEmpty) body['safety_identifier'] = safety;
  if (stream) body['stream'] = true;
  if (forceTool) body['tool_choice'] = {'type': 'image_generation'};
  return body;
}
