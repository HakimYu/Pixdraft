import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../data/studio_store.dart';
import '../models/models.dart';

class StudioImage extends StatefulWidget {
  const StudioImage({
    super.key,
    required this.store,
    required this.asset,
    this.fit = BoxFit.contain,
    this.cacheWidth,
    this.semanticLabel,
  });

  final StudioStore store;
  final ImageAsset asset;
  final BoxFit fit;
  final int? cacheWidth;
  final String? semanticLabel;

  @override
  State<StudioImage> createState() => _StudioImageState();
}

class _StudioImageState extends State<StudioImage> {
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    if (_usesBytes) _read();
  }

  @override
  void didUpdateWidget(covariant StudioImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_usesBytes &&
        (widget.store != oldWidget.store ||
            widget.asset.id != oldWidget.asset.id ||
            widget.asset.path != oldWidget.asset.path ||
            widget.asset.mime != oldWidget.asset.mime)) {
      _read();
    }
  }

  bool get _isSvg => widget.asset.mime == 'image/svg+xml';
  bool get _usesBytes => kIsWeb || _isSvg;
  void _read() {
    _bytes = widget.store.readAsset(widget.asset);
  }

  static const _loading = Center(
    child: SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        semanticsLabel: '正在读取图片',
      ),
    ),
  );
  static const _error = Center(
    child: Icon(Icons.broken_image_outlined, semanticLabel: '无法读取图片'),
  );

  @override
  Widget build(BuildContext context) {
    if (_usesBytes) {
      return FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (_, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) return _loading;
          final bytes = snapshot.data;
          if (bytes == null) return _error;
          return _isSvg
              ? SvgPicture.memory(
                  bytes,
                  fit: widget.fit,
                  semanticsLabel: widget.semanticLabel,
                  placeholderBuilder: (_) => _loading,
                  errorBuilder: (_, _, _) => _error,
                )
              : Image.memory(
                  bytes,
                  fit: widget.fit,
                  cacheWidth: widget.cacheWidth,
                  semanticLabel: widget.semanticLabel,
                  errorBuilder: (_, _, _) => _error,
                );
        },
      );
    }
    return Image.file(
      widget.store.fileFor(widget.asset),
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      semanticLabel: widget.semanticLabel,
      errorBuilder: (_, _, _) => _error,
    );
  }
}
