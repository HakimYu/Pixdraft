import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/models.dart';
import 'api_failure.dart';
import 'debug_context.dart';
import 'error_details.dart';
import 'image_payload.dart';
import 'input_preparation.dart';
import 'network_dio.dart';
import 'params.dart';
import 'request_builder.dart';
import 'sse.dart';

/// OpenAI Images / Responses 协议客户端。
///
/// 只负责构造请求、解析响应并逐张发送图片事件；图片 URL 交由调度器下载，
/// 本类不访问数据库，也不会在失败后自行重发生成请求。
class OpenAiClient implements GenerationClient {
  OpenAiClient({
    required Future<Uint8List> Function(ImageAsset) readAsset,
    required Future<int> Function(ImageAsset) assetLength,
    Dio? dio,
  // ignore: prefer_initializing_formals
  }) : _readAsset = readAsset,
       _lengthOfAsset = assetLength,
       _dio = dio ?? createNetworkDio(
         BaseOptions(connectTimeout: const Duration(seconds: 30)),
       );

  final Future<Uint8List> Function(ImageAsset) _readAsset;
  final Future<int> Function(ImageAsset) _lengthOfAsset;
  final Dio _dio;
  final Map<String, _Run> _runs = {};

  @override
  Stream<GenerationEvent> generate(GenerationInput input, String apiKey) =>
      _start(input, apiKey);

  Stream<GenerationEvent> recover(GenerationInput input, String apiKey, String remoteId) =>
      _start(input, apiKey, remoteId: remoteId);

  Stream<GenerationEvent> _start(GenerationInput input, String apiKey, {String? remoteId}) {
    final run = _Run(input.taskId);
    final controller = StreamController<GenerationEvent>();
    run.controller = controller;
    _runs[input.taskId] = run;
    controller.onCancel = () {
      run.userCancelled = true;
      run.token.cancel();
    };
    unawaited(_execute(run, input, apiKey, remoteId));
    return controller.stream;
  }

  @override
  void cancel(String taskId) {
    final run = _runs[taskId];
    if (run == null) return;
    run.userCancelled = true;
    run.token.cancel();
    if (!run.controller.isClosed) {
      run.controller.close();
    }
  }

  Future<void> _execute(_Run run, GenerationInput input, String apiKey, String? remoteId) async {
    final provider = input.provider;
    final startedAt = DateTime.now();
    run
      ..protocol = provider.protocol
      ..requestedTransport = provider.transport
      ..baseUrl = provider.baseUrl
      ..allowHttp = provider.allowHttp
      ..apiKey = apiKey
      ..timeoutSeconds = provider.timeoutSeconds;

    Object? failure;
    StackTrace? failureStack;
    var succeeded = false;

    try {
      final timeoutSeconds = provider.timeoutSeconds;
      if (timeoutSeconds < 1 || timeoutSeconds > 3600) {
        throw const FormatException('超时需为 1–3600 秒');
      }
      run.timer = Timer(Duration(seconds: timeoutSeconds), () {
        run.timedOut = true;
        run.token.cancel();
      });

      _validate(input);
      final hasInputImages = input.references.isNotEmpty;
      final model = provider.protocol != ApiProtocol.responses
          ? provider.imageModel
          : provider.toolModel;
      if (provider.protocol == ApiProtocol.responses &&
          provider.responseModel.trim().isEmpty) {
        throw const FormatException('模型 ID 不能为空');
      }
      final params = resolveParams(
        input.params,
        protocol: provider.protocol,
        imageModel: model,
        hasInputImages: hasInputImages,
      );
      run
        ..params = params
        ..model = model.trim();
      run.diagnostics = ErrorContext(input, startedAt: startedAt)
        ..model = run.model
        ..params = params;

      if (remoteId != null) {
        if (!provider.protocol.isAsync) throw StateError('当前协议不支持远端查询恢复');
        await _pollAsync(run, apiKey, params, remoteId);
      } else {
        final assets = await _loadAssets(input);
        run.diagnostics?.setAssets(
          references: [
            for (final asset in assets.references)
              (
                mime: asset.mime,
                bytes: asset.bytes.length,
                inline: asset.inlineBytes != null,
              ),
          ],
          mask: assets.mask == null
              ? null
              : (mime: assets.mask!.mime, bytes: assets.mask!.bytes.length),
          markup: assets.markup == null
              ? null
              : (mime: assets.markup!.mime, bytes: assets.markup!.bytes.length),
        );
        if (run.userCancelled) throw const _Canceled();
        if (run.timedOut) throw _timeoutFailure(timeoutSeconds);

        run.add(const GenerationEvent('started'));
        if (provider.protocol.isAsync) {
          await _runAsync(run, input, apiKey, params, assets);
        } else if (provider.protocol == ApiProtocol.images) {
          await _runImages(run, input, apiKey, params, assets);
        } else {
          await _runResponses(run, input, apiKey, params, assets);
        }
        }
        if (run.userCancelled) throw const _Canceled();
        if (run.timedOut) throw _timeoutFailure(timeoutSeconds);

      run.add(GenerationEvent('metadata', metadata: _metadata(run)));
      succeeded = true;
    } on _Canceled {
      // 用户取消：不发送错误，直接结束。
    } catch (error, stack) {
      if (run.userCancelled) {
        // 取消过程中抛出的底层错误同样静默。
      } else if (run.timedOut) {
        failure = _timeoutFailure(provider.timeoutSeconds);
        failureStack = stack;
      } else {
        failure = _wrapError(error);
        failureStack = stack;
      }
    }
    if (failure != null) {
      failure = _attachDiagnostics(failure, run.diagnostics);
    }
    if (succeeded) run.add(const GenerationEvent('done'));
    await _finish(run, failure, failureStack);
  }

  void _validate(GenerationInput input) {
    if (input.params.count < 1 || input.params.count > 10) {
      throw const FormatException('生成数量需为 1–10');
    }
    if (input.references.length > 16) throw const FormatException('参考图最多 16 张');
    if (input.prompt.trim().isEmpty && input.references.isEmpty) {
      throw const FormatException('请输入提示词或选择参考图');
    }
    if (input.mask != null && input.markup != null) {
      throw const FormatException('蒙版与标注不能同时使用');
    }
    if (input.markup != null && input.provider.protocol != ApiProtocol.images) {
      throw const FormatException('Responses 协议不支持标注');
    }
    if ((input.mask != null || input.markup != null) &&
        input.references.isEmpty) {
      throw const FormatException('蒙版或标注需要参考图');
    }
  }

  Future<_Assets> _loadAssets(GenerationInput input) async {
    final all = <ImageAsset>[
      ...input.references,
      if (input.mask != null) input.mask!,
      if (input.markup != null) input.markup!,
    ];
    var totalBytes = 0;
    for (final asset in all) {
      final length = await _assetLength(asset);
      if (length > maxReadAssetBytes) {
        throw FormatException('单张图片超过 64 MB，无法处理：${asset.path}');
      }
      totalBytes += length;
      if (totalBytes > maxReadBatchBytes) {
        throw const FormatException('本批图片总大小超过 128 MB，请减少参考图数量');
      }
    }

    // 仅 Responses 内联参考图压缩；file_id 上传、Images 与带蒙版的请求保留原图。
    final inline =
        input.provider.protocol == ApiProtocol.responses &&
        !input.provider.fileInput &&
        input.mask == null &&
        input.markup == null;

    Future<_AssetData> load(ImageAsset asset, {bool prepare = false}) async {
      Uint8List bytes;
      try {
        bytes = await _readAsset(asset);
      } on FileSystemException {
        throw FormatException('无法读取本地图片：${asset.path}');
      }
      if (bytes.isEmpty) throw FormatException('图片内容为空：${asset.path}');
      var mime = asset.mime.trim().toLowerCase();
      if (!mime.startsWith('image/')) {
        final dot = asset.path.lastIndexOf('.');
        final extension = dot >= 0 ? asset.path.substring(dot + 1) : '';
        mime = mimeForExtension(extension) ?? 'image/png';
      }
      final prepared = prepare ? await prepareInlineImage(bytes, mime) : null;
      return _AssetData(
        bytes,
        mime,
        inlineBytes: prepared?.bytes,
        inlineMime: prepared?.mime,
      );
    }

    final references = <_AssetData>[];
    for (final asset in input.references) {
      references.add(await load(asset, prepare: inline));
    }
    final mask = input.mask == null ? null : await load(input.mask!);
    final markup = input.markup == null ? null : await load(input.markup!);
    return _Assets(references, mask, markup);
  }

  Future<int> _assetLength(ImageAsset asset) async {
    try {
      return await _lengthOfAsset(asset);
    } on FileSystemException {
      throw FormatException('无法读取本地图片：${asset.path}');
    }
  }

  Future<void> _runAsync(_Run run, GenerationInput input, String apiKey,
      ResolvedParams params, _Assets assets) async {
    final invalid = input.provider.validate();
    if (invalid != null) throw FormatException(invalid);
    final wave = input.provider.protocol == ApiProtocol.wavespeed;
    if (assets.mask != null || assets.markup != null) {
      throw const FormatException('当前协议不支持蒙版或标注，请清除编辑图层');
    }
    if (assets.references.length > 10) throw const FormatException('参考图最多 10 张');
    if (wave && run.model.endsWith('/edit') && assets.references.isEmpty) {
      throw const FormatException('编辑模型至少需要一张参考图');
    }
    final endpoint = wave ? run.model : 'images/generations';
    if (wave && !RegExp(r'^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)+$').hasMatch(run.model)) {
      throw const FormatException('WaveSpeed 模型 ID 需为完整路径，例如 bytedance/seedream-v5.5/edit');
    }
    Uri uri(String path) => _asyncUri(run, path);
    final references = <String>[];
    for (final asset in assets.references) {
      if (wave) {
        references.add(imageDataUrl(asset.bytes, asset.mime));
      } else {
        if (asset.bytes.length > 30 * 1024 * 1024) throw const FormatException('EvoLink 单张参考图不能超过 30 MB');
        final form = FormData.fromMap({'file': MultipartFile.fromBytes(
          asset.bytes, filename: 'reference.${extensionForMime(asset.mime)}', contentType: mediaTypeFor(asset.mime))});
        final body = await _post(run, Uri.parse('https://files-api.evolink.ai/api/v1/files/upload/stream'), form, apiKey, json: false);
        final uploaded = _decodeJsonObject(await _readText(run, body));
        final url = uploaded['data'] is Map ? uploaded['data']['file_url'] : null;
        if (uploaded['success'] != true || url is! String || !url.startsWith('https://')) {
          throw const FormatException('EvoLink 参考图上传失败，未返回图片地址');
        }
        references.add(url);
      }
    }
    for (var i = 0; i < params.count; i++) {
      if (run.userCancelled) throw const _Canceled();
      final payload = <String, dynamic>{
        if (!wave) 'model': run.model,
        'prompt': input.prompt,
        if (references.isNotEmpty) (wave ? 'images' : 'image_urls'): references,
        if (params.size != 'auto') (wave ? 'aspect_ratio' : 'size'): params.size,
        (wave ? 'resolution' : 'quality'): wave ? params.quality.toLowerCase() : params.quality,
        'output_format': params.format,
        'background': params.background,
      };
      final body = await _post(run, uri(endpoint), payload, apiKey, json: true);
      var task = _decodeJsonObject(await _readText(run, body));
      if (wave) task = _asyncData(task);
      final id = task['id'];
      if (id is! String || id.isEmpty) throw const FormatException('服务未返回任务 ID；请先在服务商后台检查，避免重复计费');
      run.diagnostics?.note('远端任务 ID：$id');
      run.remoteTaskIds.add(id);
      run.add(RemoteSubmission(id, run.imageCount, run.protocol, _metadata(run)));
      await _pollAsync(run, apiKey, params, id, initial: task);
    }
  }

  Uri _asyncUri(_Run run, String path) => apiEndpoint(
    Uri.parse(run.baseUrl).path.replaceAll('/', '').isEmpty
      ? '${Uri.parse(run.baseUrl).origin}${run.protocol == ApiProtocol.wavespeed ? '/api/v3' : '/v1'}'
      : run.baseUrl,
    path, allowHttp: run.allowHttp,
  );

  Future<void> _pollAsync(_Run run, String apiKey, ResolvedParams params, String id,
      {Map<String, dynamic>? initial}) async {
    final wave = run.protocol == ApiProtocol.wavespeed;
    Future<Map<String, dynamic>> fetch() async {
      final response = await _dio.getUri<ResponseBody>(
        _asyncUri(run, wave ? 'predictions/${Uri.encodeComponent(id)}/result' : 'tasks/${Uri.encodeComponent(id)}'),
        cancelToken: run.token,
        options: Options(responseType: ResponseType.stream, followRedirects: false,
          validateStatus: (_) => true, headers: _authHeaders(apiKey)),
      );
      final data = response.data;
      if (data == null) throw const FormatException('服务返回了空响应');
      final text = await _readText(run, data);
      if ((response.statusCode ?? 0) < 200 || (response.statusCode ?? 0) >= 300) {
        throw ApiFailure(_errorMessage(text, status: response.statusCode), status: response.statusCode);
      }
      final task = _decodeJsonObject(text);
      return wave ? _asyncData(task) : task;
    }
    var task = initial ?? await fetch();
    while (true) {
      final status = task['status'];
      if (status == 'completed') {
        final outputs = task[wave ? 'outputs' : 'results'];
        if (outputs is! List || outputs.isEmpty) throw const FormatException('任务已完成，但未返回图片');

        for (final output in outputs) {
          if (output is! String || output.isEmpty) throw const FormatException('图片结果格式无效');
          final batch = ImageCollector(fallbackMime: params.mime, seen: {}).collect({'url': output});
          if (batch.images.isEmpty) throw const FormatException('服务未返回可用图片地址');
          for (final image in batch.images) { _emitImage(run, image); }
        }
        break;
      }
      if (['failed', 'cancelled', 'canceled', 'timeout', 'deleted'].contains(status)) {
        throw ApiFailure('远端任务 $id 失败：${task['error'] ?? '未知错误'}', remoteTerminal: true);
      }
      if (![ 'created', 'pending', 'processing', 'in_progress', 'running', 'queued' ].contains(status)) {
        throw FormatException('无法识别任务状态：$status（任务 $id）');
      }
      await Future.any([Future<void>.delayed(const Duration(seconds: 2)), run.token.whenCancel]);
      if (run.userCancelled) throw const _Canceled();
      if (run.timedOut) throw _timeoutFailure(run.timeoutSeconds);
      task = await fetch();
    }
  }

  Map<String, dynamic> _asyncData(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! Map<String, dynamic>) throw ApiFailure(_errorMessage(jsonEncode(response)));
    return data;
  }

  Future<void> _runImages(
    _Run run,
    GenerationInput input,
    String apiKey,
    ResolvedParams params,
    _Assets assets,
  ) async {
    final plans = _imagesPlans(
      params,
      assets.references.isNotEmpty,
      input.provider.transport,
    );
    try {
      await _runPlans(
        run,
        plans,
        params.count,
        (plan, count) =>
            _imagesAttempt(run, input, apiKey, params, assets, plan, count),
      );
    } catch (_) {
      if (run.split && run.imageCount > 0) {
        run.add(
          GenerationEvent('metadata', metadata: _metadata(run, partial: true)),
        );
      }
      rethrow;
    }
  }

  Future<void> _runResponses(
    _Run run,
    GenerationInput input,
    String apiKey,
    ResolvedParams params,
    _Assets assets,
  ) async {
    if (input.provider.fileInput) {
      await _prepareFileIds(
        run,
        input.provider,
        apiKey,
        assets,
        requiredByUser: true,
      );
    }
    final plans = _responsesPlans(
      params,
      input.provider.transport,
      assets.mask != null,
    );
    try {
      await _runPlans(
        run,
        plans,
        params.count,
        (plan, count) =>
            _responsesAttempt(run, input, apiKey, params, assets, plan, count),
      );
    } catch (_) {
      if (run.split && run.imageCount > 0) {
        run.add(
          GenerationEvent('metadata', metadata: _metadata(run, partial: true)),
        );
      }
      rethrow;
    }
  }

  Future<void> _runPlans(
    _Run run,
    List<_Plan> plans,
    int count,
    Future<void> Function(_Plan plan, int count) attempt,
  ) async {
    for (var i = 0; i < plans.length; i++) {
      while (true) {
        try {
          await attempt(plans[i], count);
          return;
        } on ApiFailure catch (error) {
          if (kIsWeb ||
              !error.fromHttpResponse ||
              run.userCancelled ||
              run.timedOut ||
              run.imageCount > 0) {
            rethrow;
          }
          if (count > 1 && _isUnsupportedCount(error)) {
            run.diagnostics?.note('服务不支持一次生成 $count 张，已拆分为单图请求重试');
            await _split(run, plans, count, attempt);
            return;
          }
          if (i + 1 >= plans.length) rethrow;
          final next = plans[i + 1];
          if (!_canAdvance(error, plans[i], next)) rethrow;
          if (plans[i].transport == _Transport.stream &&
              next.transport == _Transport.json) {
            run.fellBack = true;
            run.diagnostics?.note('流式传输失败，已回退 JSON 传输重试');
          }
          if (plans[i].body == _Body.json && next.body == _Body.multipart) {
            run.diagnostics?.note('JSON 请求体失败，已改用 multipart 重试');
          }
          if (next.compat) {
            run.compatibility = true;
            run.diagnostics?.note('参数不被支持，已启用兼容模式重试');
          }
          break;
        }
      }
    }
  }

  Future<void> _split(
    _Run run,
    List<_Plan> plans,
    int count,
    Future<void> Function(_Plan plan, int count) attempt,
  ) async {
    run.split = true;
    for (var i = 0; i < count; i++) {
      await _runPlans(run, plans, 1, attempt);
    }
  }

  bool _isUnsupportedCount(ApiFailure error) {
    if (!_retryableStatuses.contains(error.status)) return false;
    return _unsupportedCountPattern.hasMatch(error.message.split('\n').first);
  }

  bool _canAdvance(ApiFailure error, _Plan current, _Plan next) {
    final status = error.status;
    if (status == null || !_retryableStatuses.contains(status)) return false;
    if (next.compat && !current.compat) {
      return _parameterUnsupportedPattern.hasMatch(error.message.split('\n').first);
    }
    if (current.transport == _Transport.stream &&
        next.transport == _Transport.json) {
      return _streamUnsupportedPattern.hasMatch(error.message.split('\n').first);
    }
    if (current.transport == _Transport.json &&
        next.transport == _Transport.stream) {
      return _streamRequiredPattern.hasMatch(error.message.split('\n').first);
    }
    if (current.body == _Body.json && next.body == _Body.multipart) {
      return _multipartUnsupportedPattern.hasMatch(error.message.split('\n').first);
    }
    return false;
  }

  List<_Plan> _imagesPlans(
    ResolvedParams params,
    bool edit,
    TransportMode mode,
  ) {
    final jsonBody = _Plan(_Transport.json, _Body.json);
    final multipartBody = _Plan(_Transport.json, _Body.multipart);
    if (!params.canStream || mode == TransportMode.json) {
      return edit ? [jsonBody, multipartBody] : [jsonBody];
    }
    if (!edit) {
      return [_Plan(_Transport.stream, _Body.json), jsonBody];
    }
    final jsonPlans = [jsonBody, multipartBody];
    final streamPlans = [
      _Plan(_Transport.stream, _Body.json),
      _Plan(_Transport.stream, _Body.multipart),
    ];
    return mode == TransportMode.stream
        ? [...streamPlans, ...jsonPlans]
        : [...jsonPlans, ...streamPlans];
  }

  List<_Plan> _responsesPlans(
    ResolvedParams params,
    TransportMode mode,
    bool hasMask,
  ) {
    if (!params.canStream || mode == TransportMode.json) {
      return [_Plan(_Transport.json, _Body.json, explicit: hasMask)];
    }
    final streamPlan = _Plan(_Transport.stream, _Body.json, explicit: hasMask);
    final jsonPlan = _Plan(_Transport.json, _Body.json, explicit: hasMask);
    if (hasMask) return [jsonPlan, streamPlan];
    if (mode == TransportMode.stream) {
      return [
        streamPlan,
        jsonPlan,
        _Plan(_Transport.json, _Body.json, compat: true),
      ];
    }
    return [
      streamPlan,
      jsonPlan,
      _Plan(_Transport.json, _Body.json, compat: true),
    ];
  }

  Future<void> _imagesAttempt(
    _Run run,
    GenerationInput input,
    String apiKey,
    ResolvedParams params,
    _Assets assets,
    _Plan plan,
    int count,
  ) async {
    final provider = input.provider;
    final edit = assets.references.isNotEmpty;
    final uri = apiEndpoint(
      provider.baseUrl,
      edit ? 'images/edits' : 'images/generations',
      allowHttp: provider.allowHttp,
    );
    final stream = plan.transport == _Transport.stream;

    final Object data;
    if (plan.body == _Body.multipart) {
      data = imagesForm(
        provider: provider,
        prompt: input.prompt,
        params: params,
        count: count,
        stream: stream,
        images: [
          for (var i = 0; i < assets.references.length; i++)
            MultipartFile.fromBytes(
              assets.references[i].bytes,
              filename:
                  'input-${i + 1}.${extensionForMime(assets.references[i].mime)}',
              contentType: mediaTypeFor(assets.references[i].mime),
            ),
        ],
        mask: assets.mask == null
            ? null
            : MultipartFile.fromBytes(
                assets.mask!.bytes,
                filename: 'mask.${extensionForMime(assets.mask!.mime)}',
                contentType: mediaTypeFor(assets.mask!.mime),
              ),
        markup: assets.markup == null
            ? null
            : MultipartFile.fromBytes(
                assets.markup!.bytes,
                filename: 'markup.${extensionForMime(assets.markup!.mime)}',
                contentType: mediaTypeFor(assets.markup!.mime),
              ),
      );
    } else {
      data = imagesBody(
        provider: provider,
        prompt: input.prompt,
        params: params,
        count: count,
        stream: stream,
        edit: edit,
        imageUrls: [
          for (final asset in assets.references)
            imageDataUrl(asset.bytes, asset.mime),
        ],
        maskUrl: assets.mask == null
            ? null
            : imageDataUrl(assets.mask!.bytes, assets.mask!.mime),
        markupUrl: assets.markup == null
            ? null
            : imageDataUrl(assets.markup!.bytes, assets.markup!.mime),
      );
    }

    final response = await _post(
      run,
      uri,
      data,
      apiKey,
      json: plan.body == _Body.json,
      plan: plan,
    );
    final collector = ImageCollector(fallbackMime: params.mime, seen: run.seen);
    final contentType = _contentType(response);
    if (stream || contentType.contains('text/event-stream')) {
      await _consumeImages(run, response, params, collector);
    } else {
      final text = await _readText(run, response);
      _emitJsonImages(run, collector, text);
      run.appliedMetadata = collector.appliedMetadata;
    }
    run
      ..lastPlan = plan
      ..lastCount = count;
  }

  Future<void> _prepareFileIds(
    _Run run,
    ProviderConfig provider,
    String apiKey,
    _Assets assets, {
    required bool requiredByUser,
  }) async {
    final ids = <String>[];
    try {
      for (var i = 0; i < assets.references.length; i++) {
        ids.add(
          await _uploadFile(
            run,
            provider,
            apiKey,
            assets.references[i],
            'input-${i + 1}.${extensionForMime(assets.references[i].mime)}',
          ),
        );
      }
      String? maskId;
      if (assets.mask != null) {
        maskId = await _uploadFile(
          run,
          provider,
          apiKey,
          assets.mask!,
          'mask.${extensionForMime(assets.mask!.mime)}',
        );
      }
      run
        ..referenceFileIds = ids
        ..maskFileId = maskId
        ..fileMode = true;
    } on ApiFailure catch (error) {
      if (requiredByUser && _isUnsupportedFileUpload(error)) {
        throw const FormatException(
          '当前服务不支持 Responses 参考图 file_id 上传，请关闭 file_id 或改用内联图片',
        );
      }
      rethrow;
    }
  }

  Future<String> _uploadFile(
    _Run run,
    ProviderConfig provider,
    String apiKey,
    _AssetData data,
    String filename,
  ) async {
    final uri = apiEndpoint(
      provider.baseUrl,
      'files',
      allowHttp: provider.allowHttp,
    );
    final form = FormData();
    form.fields.add(const MapEntry('purpose', 'vision'));
    form.files.add(
      MapEntry(
        'file',
        MultipartFile.fromBytes(
          data.bytes,
          filename: filename,
          contentType: mediaTypeFor(data.mime),
        ),
      ),
    );
    final response = await _post(run, uri, form, apiKey, json: false);
    final text = await _readText(run, response);
    final decoded = _decodeJsonObject(text);
    final id = decoded['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('文件上传成功，但未返回 file_id');
    }
    run.uploadedFileIds.add(id);
    return id;
  }

  bool _isUnsupportedFileUpload(ApiFailure error) {
    if (_retryableStatuses.contains(error.status)) return true;
    return _fileUploadUnsupportedPattern.hasMatch(error.message.split('\n').first);
  }

  Future<void> _responsesAttempt(
    _Run run,
    GenerationInput input,
    String apiKey,
    ResolvedParams params,
    _Assets assets,
    _Plan plan,
    int count,
  ) async {
    try {
      await _sendResponses(run, input, apiKey, params, assets, plan, count);
    } on ApiFailure catch (error) {
      if (error.status == 413 &&
          error.fromHttpResponse &&
          !run.fileMode &&
          !input.provider.fileInput &&
          assets.references.isNotEmpty) {
        run.diagnostics?.note('请求体过大（HTTP 413），已改用 file_id 上传重试');
        await _prepareFileIds(
          run,
          input.provider,
          apiKey,
          assets,
          requiredByUser: false,
        );
        await _sendResponses(run, input, apiKey, params, assets, plan, count);
        return;
      }
      rethrow;
    }
  }

  Future<void> _sendResponses(
    _Run run,
    GenerationInput input,
    String apiKey,
    ResolvedParams params,
    _Assets assets,
    _Plan plan,
    int count,
  ) async {
    final provider = input.provider;
    final uri = apiEndpoint(
      provider.baseUrl,
      'responses',
      allowHttp: provider.allowHttp,
    );
    final stream = plan.transport == _Transport.stream;

    final images = <Map<String, dynamic>>[];
    for (var i = 0; i < assets.references.length; i++) {
      final asset = assets.references[i];
      if (run.fileMode) {
        images.add({'type': 'input_image', 'file_id': run.referenceFileIds[i]});
      } else {
        images.add({
          'type': 'input_image',
          'image_url': imageDataUrl(
            asset.inlineBytes ?? asset.bytes,
            asset.inlineMime ?? asset.mime,
          ),
        });
      }
    }
    Map<String, dynamic>? mask;
    if (assets.mask != null) {
      if (run.fileMode) {
        if (run.maskFileId == null) {
          throw const FormatException('蒙版上传未返回 file_id');
        }
        mask = {'file_id': run.maskFileId};
      } else {
        mask = {
          'image_url': imageDataUrl(assets.mask!.bytes, assets.mask!.mime),
        };
      }
    }

    final body = responsesBody(
      provider: provider,
      prompt: responsesPrompt(
        input.prompt,
        compatibility: provider.promptCompatibility,
      ),
      params: params,
      count: count,
      stream: stream,
      images: images,
      mask: mask,
      explicitAction: plan.explicit,
      forceTool: plan.explicit,
    );

    final response = await _post(
      run,
      uri,
      body,
      apiKey,
      json: true,
      plan: plan,
    );
    final collector = ImageCollector(fallbackMime: params.mime, seen: run.seen);
    final contentType = _contentType(response);
    if (stream || contentType.contains('text/event-stream')) {
      await _consumeResponses(run, response, params, collector);
    } else {
      final text = await _readText(run, response);
      _emitJsonImages(run, collector, text);
      run.appliedMetadata = collector.appliedMetadata;
    }
    run
      ..lastPlan = plan
      ..lastCount = count;
  }

  Future<ResponseBody> _post(
    _Run run,
    Uri uri,
    Object data,
    String apiKey, {
    required bool json,
    _Plan? plan,
  }) async {
    if (run.userCancelled) throw const _Canceled();
    final started = DateTime.now();
    final Response<ResponseBody> response;
    try {
      response = await _dio.postUri<ResponseBody>(
        uri,
        data: data,
        cancelToken: run.token,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          followRedirects: !run.protocol.isAsync,
          contentType: json ? Headers.jsonContentType : null,
          headers: _authHeaders(apiKey),
        ),
      );
    } on DioException catch (error) {
      if (run.userCancelled) throw const _Canceled();
      if (run.timedOut) throw _timeoutFailure(run.timeoutSeconds);
      if (error.type == DioExceptionType.cancel) throw const _Canceled();
      run.diagnostics?.record(
        url: uri,
        elapsed: DateTime.now().difference(started),
        transport: plan?.transport.name ?? _Transport.json.name,
        body: plan?.body.name ?? _Body.json.name,
        compat: plan?.compat ?? false,
        error: _dioErrorLabel(error),
      );
      rethrow;
    }
    final body = response.data;
    if (body == null) throw const FormatException('服务返回了空响应');
    final status = response.statusCode ?? 0;
    final requestId = _requestId(response);
    if (status < 200 || status >= 300) {
      final text = await _readText(run, body);
      run.diagnostics?.record(
        url: uri,
        elapsed: DateTime.now().difference(started),
        transport: plan?.transport.name ?? _Transport.json.name,
        body: plan?.body.name ?? _Body.json.name,
        compat: plan?.compat ?? false,
        status: status,
        requestId: requestId,
        response: summarizeResponseBody(text),
      );
      throw ApiFailure(
        _errorMessage(text, status: status),
        status: status,
        fromHttpResponse: true,
      );
    }
    run.diagnostics?.record(
      url: uri,
      elapsed: DateTime.now().difference(started),
      transport: plan?.transport.name ?? _Transport.json.name,
      body: plan?.body.name ?? _Body.json.name,
      compat: plan?.compat ?? false,
      status: status,
      requestId: requestId,
    );
    return body;
  }

  String? _requestId(Response<ResponseBody> response) {
    for (final entry in response.headers.map.entries) {
      final key = entry.key.toLowerCase();
      if ((key == 'x-request-id' ||
              key == 'request-id' ||
              key == 'x-oneapi-request-id') &&
          entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  String _dioErrorLabel(DioException error) {
    final message = error.message?.trim();
    return message == null || message.isEmpty
        ? error.type.name
        : '${error.type.name}：$message';
  }

  Object _attachDiagnostics(Object failure, ErrorContext? context) {
    if (context == null || failure is! FormatException) return failure;
    if (failure.message.contains('诊断信息')) return failure;
    final details = context.render();
    if (details.isEmpty) return failure;
    final message = '${failure.message}\n\n$details';
    return failure is ApiFailure
        ? ApiFailure(

            message,
            status: failure.status,
            fromHttpResponse: failure.fromHttpResponse,
            remoteTerminal: failure.remoteTerminal,
          )
        : FormatException(message);
  }

  Map<String, String> _authHeaders(String apiKey) {
    final key = apiKey.trim();
    return key.isEmpty ? const {} : {'Authorization': 'Bearer $key'};
  }

  String _contentType(ResponseBody body) {
    for (final entry in body.headers.entries) {
      if (entry.key.toLowerCase() == Headers.contentTypeHeader &&
          entry.value.isNotEmpty) {
        return entry.value.first.toLowerCase();
      }
    }
    return '';
  }

  Future<String> _readText(_Run run, ResponseBody body) async {
    final builder = BytesBuilder(copy: false);
    await _readChunks(run, body, (chunk) {
      builder.add(chunk);
      if (builder.length > 64 * 1024 * 1024) {
        throw const FormatException('服务响应过大');
      }
    });
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> _readChunks(
    _Run run,
    ResponseBody body,
    void Function(List<int> chunk) onChunk,
  ) async {
    try {
      await for (final chunk in body.stream) {
        if (run.userCancelled) throw const _Canceled();
        onChunk(chunk);
      }
    } on _Canceled {
      rethrow;
    } on ApiFailure {
      rethrow;
    } on FormatException {
      rethrow;
    } on DioException catch (error) {
      if (run.userCancelled) throw const _Canceled();
      if (run.timedOut) throw _timeoutFailure(run.timeoutSeconds);
      if (error.type == DioExceptionType.cancel) throw const _Canceled();
      throw const FormatException('读取响应失败，已停止且不会自动重发');
    } catch (_) {
      if (run.userCancelled) throw const _Canceled();
      if (run.timedOut) throw _timeoutFailure(run.timeoutSeconds);
      throw const FormatException('读取响应失败，已停止且不会自动重发');
    }
  }

  Future<void> _consumeImages(
    _Run run,
    ResponseBody body,
    ResolvedParams params,
    ImageCollector collector,
  ) async {
    var sawEvents = false;
    var sawPayload = false;
    var eventCount = 0;
    final parser = SseParser((event) {
      sawEvents = true;
      eventCount++;
      if (_isPartialEvent(event)) {
        final preview = _previewFrom(event, params.mime);
        if (preview?.bytes != null) {
          run.add(
            GenerationEvent(
              'preview',
              bytes: preview!.bytes,
              mime: preview.mime,
            ),
          );
        }
      }
      final json = event.json;
      if (json == null) return false;
      final failure = _eventFailure(json);
      if (failure != null) throw ApiFailure(failure);
      final batch = collector.collect(json);
      sawPayload = sawPayload || batch.hadPayload;
      for (final image in batch.images) {
        _emitImage(run, image);
      }
      return _isCompletedImages(json);
    });

    try {
      await _readChunks(run, body, parser.add);
    } on ApiFailure {
      run.diagnostics?.note('流式响应返回错误事件（已收到 $eventCount 个事件）');
      rethrow;
    } on FormatException {
      run.diagnostics?.note('流式响应读取中断（已收到 $eventCount 个事件），未自动重发');
      rethrow;
    }
    if (!parser.stopped) parser.close();
    if (run.userCancelled) throw const _Canceled();

    if (!sawEvents) {
      _emitJsonImages(run, collector, parser.text);
    } else if (!sawPayload) {
      run.diagnostics?.note('流式响应结束但未收到完整图片（共 $eventCount 个事件）');
      throw const FormatException('流式接口已返回事件，但未收到完整结果。可切换为 JSON 模式后重试。');
    }
    run.appliedMetadata = collector.appliedMetadata;
  }

  Future<void> _consumeResponses(
    _Run run,
    ResponseBody body,
    ResolvedParams params,
    ImageCollector collector,
  ) async {
    var sawEvents = false;
    var sawPayload = false;
    var eventCount = 0;
    final parser = SseParser((event) {
      sawEvents = true;
      eventCount++;
      if (_isPartialEvent(event)) {
        final preview = _previewFrom(event, params.mime);
        if (preview?.bytes != null) {
          run.add(
            GenerationEvent(
              'preview',
              bytes: preview!.bytes,
              mime: preview.mime,
            ),
          );
        }
      }
      final json = event.json;
      if (json == null) return false;
      final failure = _eventFailure(json);
      if (failure != null) throw ApiFailure(failure);
      final batch = collector.collect(json);
      sawPayload = sawPayload || batch.hadPayload;
      for (final image in batch.images) {
        _emitImage(run, image);
      }
      return json['type'] == 'response.completed';
    });

    try {
      await _readChunks(run, body, parser.add);
    } on ApiFailure {
      run.diagnostics?.note('流式响应返回错误事件（已收到 $eventCount 个事件）');
      rethrow;
    } on FormatException {
      run.diagnostics?.note('流式响应读取中断（已收到 $eventCount 个事件），未自动重发');
      rethrow;
    }
    if (!parser.stopped) parser.close();
    if (run.userCancelled) throw const _Canceled();

    if (!sawEvents) {
      _emitJsonImages(run, collector, parser.text);
    } else if (!sawPayload) {
      run.diagnostics?.note('流式响应结束但未收到完整图片（共 $eventCount 个事件）');
      throw const FormatException('流式接口已返回事件，但未收到完整结果。可切换为 JSON 模式后重试。');
    }
    run.appliedMetadata = collector.appliedMetadata;
  }

  void _emitJsonImages(_Run run, ImageCollector collector, String text) {
    final decoded = _decodeJsonObject(text);
    final failure = _eventFailure(decoded);
    if (failure != null) throw ApiFailure(failure);
    final batch = collector.collect(decoded);
    for (final image in batch.images) {
      _emitImage(run, image);
    }
    if (!batch.hadPayload) throw const FormatException('接口未返回可用图片数据');
  }

  void _emitImage(_Run run, ImagePayload image) {
    run.imageCount++;
    if (image.url != null) {
      run.add(
        GenerationEvent(
          'image',
          url: image.url,
          mime: image.mime,
          key: image.signature,
        ),
      );
    } else if (image.bytes != null) {
      run.add(
        GenerationEvent(
          'image',
          bytes: image.bytes,
          mime: image.mime,
          key: image.signature,
        ),
      );
    }
  }

  bool _isPartialEvent(SseEvent event) =>
      event.event.contains('partial_image') ||
      event.data.contains('partial_image');

  ImagePayload? _previewFrom(SseEvent event, String fallbackMime) {
    final map = event.json;
    if (map == null) return null;
    final type = map['type'];
    final isPartial =
        _isPartialEvent(event) ||
        (type is String && type.contains('partial_image'));
    if (!isPartial) return null;
    final b64 =
        _nonEmpty(map['partial_image_b64']) ??
        _nonEmpty(map['b64_json']) ??
        _nonEmpty(map['result']);
    if (b64 == null) return null;
    final outputFormat = map['output_format'];
    final mime = outputFormat is String && outputFormat.isNotEmpty
        ? mimeForFormat(outputFormat)
        : fallbackMime;
    return ImagePayload(
      signature: 'preview:${map['partial_image_index'] ?? ''}',
      bytes: _decodeImageBase64(b64),
      mime: mime,
    );
  }

  bool _isCompletedImages(Map<String, dynamic> payload) {
    final type = payload['type'];
    if (type is! String || type.isEmpty || type.contains('partial_image')) {
      return false;
    }
    if (!_hasDirectImagePayload(payload)) return false;
    return type.endsWith('.completed');
  }

  bool _hasDirectImagePayload(Map<dynamic, dynamic> payload) {
    for (final key in const ['b64_json', 'result', 'url', 'image_url']) {
      final value = payload[key];
      if (value is String && value.isNotEmpty) return true;
    }
    return false;
  }

  String? _eventFailure(Map<String, dynamic> payload) {
    final type = payload['type'];
    final response = payload['response'];
    final status = response is Map ? response['status'] : null;
    final error = payload['error'];
    final failed =
        (type is String &&
            (type == 'error' ||
                type == 'failed' ||
                type.endsWith('.failed'))) ||
        status == 'failed' ||
        error != null;
    if (!failed) return null;
    return describeApiError(payload);
  }

  Map<String, dynamic> _decodeJsonObject(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 下方统一报错。
    }
    throw const FormatException('接口返回了无法解析的响应');
  }

  String _errorMessage(String text, {int? status}) =>
      kIsWeb && status != null && status >= 300 && status < 400
      ? 'Web 请求拒绝服务端重定向，请使用最终地址后重试'
      : describeApiError(text, status: status);

  String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  Uint8List _decodeImageBase64(String value) {
    final compact = value.replaceAll(RegExp(r'\s'), '');
    late Uint8List bytes;
    try {
      bytes = base64Decode(compact);
    } on FormatException {
      throw const FormatException('图片 base64 数据格式无效');
    }
    if (bytes.isEmpty) throw const FormatException('图片内容为空');
    return bytes;
  }

  Map<String, dynamic> _metadata(_Run run, {bool partial = false}) {
    final params = run.params;
    final plan = run.lastPlan;
    final metadata = <String, dynamic>{
      'protocol': run.protocol.name,
      if (run.remoteTaskIds.isNotEmpty) 'remote_task_ids': List<String>.of(run.remoteTaskIds),
      'requested_transport': run.requestedTransport.name,
      'transport': plan?.transport.name ?? 'json',
      'fallback_from_stream': run.fellBack,
      'body': plan?.body.name ?? 'json',
      'model': run.model,
      'size': params.size,
      'quality': params.quality,
      'format': params.format,
      'count': params.count,
      'request_count': run.lastCount,
      'background': params.background,
      'delivered': run.imageCount,
      'split': run.split,
      'compatibility': run.compatibility || (plan?.compat ?? false),
      'file_input': run.protocol == ApiProtocol.responses
          ? (run.fileMode ? 'file_id' : 'inline')
          : 'inline',
    };
    final applied = run.appliedMetadata;
    if (applied != null) metadata['applied'] = applied;
    if (partial) metadata['partial'] = true;
    return metadata;
  }

  Object _wrapError(Object error) {
    if (error is FormatException || error is StateError) return error;
    if (error is _Canceled) return error;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.cancel:
          return const _Canceled();
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return const FormatException('请求超时，已停止且不会自动重发');
        case DioExceptionType.connectionError:
          return FormatException(kIsWeb
              ? 'Web 请求失败，请检查服务是否允许跨域（CORS），已停止且不会自动重发'
              : '网络连接失败，已停止且不会自动重发');
        case DioExceptionType.badResponse:
          return FormatException(
            '服务返回了无法处理的状态：${error.response?.statusCode ?? '未知'}',
          );
        case DioExceptionType.badCertificate:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.unknown:
          return FormatException('网络请求失败：${error.message ?? '未知错误'}');
      }
    }
    if (error is SocketException) {
      return const FormatException('网络连接失败，已停止且不会自动重发');
    }
    return FormatException('请求失败：$error');
  }

  FormatException _timeoutFailure(int seconds) =>
      FormatException('请求超时（$seconds 秒），已停止且不会自动重发');

  Future<void> _finish(_Run run, [Object? error, StackTrace? stack]) async {
    if (run.finished) return;
    run.finished = true;
    run.timer?.cancel();
    await _cleanupUploads(run);
    if (!run.controller.isClosed) {
      if (error != null) run.controller.addError(error, stack);
      await run.controller.close();
    }
    if (identical(_runs[run.taskId], run)) _runs.remove(run.taskId);
  }

  Future<void> _cleanupUploads(_Run run) async {
    final ids = List<String>.of(run.uploadedFileIds);
    run.uploadedFileIds.clear();
    for (final id in ids) {
      try {
        final uri = apiEndpoint(
          run.baseUrl,
          'files/${Uri.encodeComponent(id)}',
          allowHttp: run.allowHttp,
        );
        await _dio.deleteUri<void>(
          uri,
          options: Options(
            validateStatus: (_) => true,
            headers: _authHeaders(run.apiKey),
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
        );
      } catch (_) {
        // 清理失败不影响作品。
      }
    }
  }
}

class RemoteSubmission extends GenerationEvent {
  RemoteSubmission(this.remoteId, this.position, this.protocol, Map<String, dynamic> metadata)
    : super('metadata', metadata: {...metadata, 'remote_task_id': remoteId});

  final String remoteId;
  final int position;
  final ApiProtocol protocol;
}

class _Run {
  _Run(this.taskId);

  final String taskId;
  final CancelToken token = CancelToken();
  late StreamController<GenerationEvent> controller;
  Timer? timer;
  bool userCancelled = false;
  bool timedOut = false;
  bool finished = false;
  int imageCount = 0;
  final Set<String> seen = {};
  final List<String> uploadedFileIds = [];
  final List<String> remoteTaskIds = [];
  List<String> referenceFileIds = const [];
  String? maskFileId;
  bool fileMode = false;
  bool fellBack = false;
  bool split = false;
  bool compatibility = false;
  _Plan? lastPlan;
  int? lastCount;
  Map<String, dynamic>? appliedMetadata;
  ErrorContext? diagnostics;
  late ResolvedParams params;
  late ApiProtocol protocol;
  late TransportMode requestedTransport;
  late String model;
  late String baseUrl;
  late bool allowHttp;
  late String apiKey;
  late int timeoutSeconds;

  void add(GenerationEvent event) {
    if (!controller.isClosed) controller.add(event);
  }
}

class _Assets {
  _Assets(this.references, this.mask, this.markup);

  final List<_AssetData> references;
  final _AssetData? mask;
  final _AssetData? markup;
}

class _AssetData {
  _AssetData(this.bytes, this.mime, {this.inlineBytes, this.inlineMime});

  final Uint8List bytes;
  final String mime;

  /// Responses 内联请求使用的压缩版本；为 null 时直接用原图。
  final Uint8List? inlineBytes;
  final String? inlineMime;
}

enum _Transport { json, stream }

enum _Body { json, multipart }

class _Plan {
  const _Plan(
    this.transport,
    this.body, {
    this.compat = false,
    this.explicit = false,
  });

  final _Transport transport;
  final _Body body;
  final bool compat;
  final bool explicit;
}

class _Canceled implements Exception {
  const _Canceled();
}

const _retryableStatuses = {400, 404, 405, 415, 422, 501};

final _unsupportedCountPattern = RegExp(
  r'(unknown parameter.*\bn\b|invalid.*\bn\b|unsupported.*\bn\b|\bn\b.*(?:not supported|unsupported|unknown|invalid)|output count|number of images|does not support n|n is not supported)',
  caseSensitive: false,
);

final _streamUnsupportedPattern = RegExp(
  r"(only false is allowed for this model|field\s*stream\s*invalid|stream(ing)?[^.]{0,40}(not (supported|allowed)|unsupported|disabled)|(not|never|no|doesn't|does not|do not|can't|cannot)\s+support(ed|ing)?[^.]{0,20}stream(ing)?|(not (supported|allowed)|unsupported)[^.]{0,20}stream(ing)?)",
  caseSensitive: false,
);

final _streamRequiredPattern = RegExp(
  r'stream(ing)?[^.]{0,40}(required|must be true|only)',
  caseSensitive: false,
);

final _multipartUnsupportedPattern = RegExp(
  r'(multipart|form-data|image\[\]|file upload|not implemented|unsupported)',
  caseSensitive: false,
);

final _parameterUnsupportedPattern = RegExp(
  r'(tool_choice|image_generation|unknown parameter|unsupported|not supported|invalid.*(?:tool|action|parameter)|action|input.*(?:must|should).*(?:list|array)|expected.*(?:list|array))',
  caseSensitive: false,
);

final _fileUploadUnsupportedPattern = RegExp(
  r'(files|multipart|file upload|file_id|vision|unsupported|not implemented)',
  caseSensitive: false,
);
