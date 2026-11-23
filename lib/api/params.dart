import 'dart:math';

import '../models/models.dart';
import 'async_image_models.dart';
const asyncAspectRatios = ['1:1', '1:2', '2:1', '1:3', '3:1', '2:3', '3:2', '3:4', '4:3', '4:5', '5:4', '9:16', '16:9', '9:21', '21:9'];

List<String> aspectRatiosFor(ApiProtocol protocol) => protocol == ApiProtocol.evolink ? asyncAspectRatios.where((s) => !['1:2', '2:1', '1:3', '3:1'].contains(s)).toList() : asyncAspectRatios;
const _baseQualities = {'auto', 'low', 'medium', 'high'};
const _extendedQualities = {'auto', 'low', 'medium', 'high', 'xhigh', 'max'};
const _backgrounds = {'auto', 'opaque', 'transparent'};
const _inputFidelities = {'high', 'low'};
const _complexities = {'low', 'medium', 'high'};
const _formats = {'png', 'jpeg', 'webp', 'gif', 'svg'};

const _sizeMultiple = 16;
const _maxEdge = 3840;
const _maxAspectRatio = 3;
const _minPixels = 655360;
const _maxPixels = 8294400;

bool isGptImage25Model(String model) {
  final value = model.trim().toLowerCase();
  return value.contains('gpt-image-2.5') ||
      value.contains('gpt-images-2.5') ||
      value.contains('gpt-image-2.6') ||
      value.contains('gpt-images-2.6');
}

String normalizeSize(String size) {
  final trimmed = size.trim();
  final match = RegExp(r'^(\d+)\s*[xX×]\s*(\d+)$').firstMatch(trimmed);
  if (match == null) return trimmed;
  final width = int.parse(match.group(1)!);
  final height = int.parse(match.group(2)!);
  if (width <= 0 || height <= 0) return trimmed;

  int roundTo(int value) => max(_sizeMultiple, (value / _sizeMultiple).round() * _sizeMultiple);
  int floorTo(num value) => max(_sizeMultiple, (value / _sizeMultiple).floor() * _sizeMultiple);
  int ceilTo(num value) => max(_sizeMultiple, (value / _sizeMultiple).ceil() * _sizeMultiple);

  var w = roundTo(width);
  var h = roundTo(height);
  for (var i = 0; i < 4; i++) {
    final longest = max(w, h);
    if (longest > _maxEdge) {
      final scale = _maxEdge / longest;
      w = floorTo(w * scale);
      h = floorTo(h * scale);
    }
    if (w / h > _maxAspectRatio) {
      w = floorTo(h * _maxAspectRatio);
    } else if (h / w > _maxAspectRatio) {
      h = floorTo(w * _maxAspectRatio);
    }
    final pixels = w * h;
    if (pixels > _maxPixels) {
      final scale = sqrt(_maxPixels / pixels);
      w = floorTo(w * scale);
      h = floorTo(h * scale);
    } else if (pixels < _minPixels) {
      final scale = sqrt(_minPixels / pixels);
      w = ceilTo(w * scale);
      h = ceilTo(h * scale);
    }
  }
  return '${w}x$h';
}

String mimeForFormat(String format) => switch (format) {
      'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      _ => 'image/png',
    };

String extensionForMime(String mime) => switch (mime.toLowerCase()) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/svg+xml' => 'svg',
      _ => 'png',
    };

String? mimeForExtension(String extension) => switch (extension.toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'svg' => 'image/svg+xml',
      _ => null,
    };

class ResolvedParams {
  const ResolvedParams({
    required this.size,
    required this.quality,
    required this.format,
    required this.background,
    required this.moderation,
    required this.count,
    required this.compression,
    required this.gifFrames,
    required this.gifDuration,
    required this.inputFidelity,
    required this.complexity,
  });

  final String size, quality, format, background, moderation;
  final int count, compression, gifFrames, gifDuration;
  final String? inputFidelity, complexity;

  bool get canStream => format != 'gif' && format != 'svg';
  String get mime => mimeForFormat(format);
  bool get hasCompression => format == 'jpeg' || format == 'webp';
}

ResolvedParams resolveParams(
  GenerationParams params, {
  required ApiProtocol protocol,
  required String imageModel,
  required bool hasInputImages,
  AsyncImageRules? asyncRules,
  bool recovering = false,
}) {
  if (imageModel.trim().isEmpty) throw const FormatException('模型 ID 不能为空');

  final formatValue = params.format.trim().toLowerCase();
  if (!_formats.contains(formatValue)) throw FormatException('不支持的图片格式：${params.format}');
  var format = formatValue;

  var background = params.background.trim().toLowerCase();
  if (!_backgrounds.contains(background)) background = 'auto';

  if (protocol.isAsync) {
    final rules = asyncRules ?? asyncImageRules(protocol, imageModel);
    background = rules.backgrounds.contains(background) ? background : 'auto';
    final size = recovering ? params.size : rules.resolveSize(params.size);
    final quality = recovering ? params.quality : rules.resolveQuality(params.quality);
    return ResolvedParams(
      size: size, quality: quality,
      format: recovering ? format : rules.resolveFormat(format, background),
      background: background, moderation: 'auto', count: params.count.clamp(1, 10),
      compression: 100, gifFrames: 9, gifDuration: 200,
      inputFidelity: null, complexity: null,
    );
  }
  final rawQuality = params.quality.trim().toLowerCase();
  var quality =
      _baseQualities.contains(rawQuality) || _extendedQualities.contains(rawQuality)
      ? rawQuality
      : 'auto';
  if ((quality == 'xhigh' || quality == 'max') && !isGptImage25Model(imageModel)) {
    quality = 'high';
  }
  var count = params.count.clamp(1, 10);
  var compression = params.compression;
  var frames = params.gifFrames.clamp(2, 16);
  final maxDuration = protocol == ApiProtocol.responses ? 2000 : 0x7fffffff;
  final duration = params.gifDuration.clamp(20, maxDuration);

  final fidelity = params.inputFidelity.trim().toLowerCase();
  final complexity = params.complexity.trim().toLowerCase();

  if (format == 'svg') {
    count = 1;
    if (background == 'transparent') background = 'opaque';
  }
  if (background == 'transparent' && format == 'jpeg') {
    format = 'png';
    compression = 100;
  }
  if (background == 'transparent' && format == 'gif') background = 'opaque';

  return ResolvedParams(
    size: normalizeSize(params.size).isEmpty ? 'auto' : normalizeSize(params.size),
    quality: quality,
    format: format,
    background: background,
    moderation: params.moderation.trim().isEmpty ? 'auto' : params.moderation.trim(),
    count: count,
    compression: compression,
    gifFrames: frames,
    gifDuration: duration,
    inputFidelity: hasInputImages && _inputFidelities.contains(fidelity) ? fidelity : null,
    complexity: _complexities.contains(complexity) ? complexity : null,
  );
}
