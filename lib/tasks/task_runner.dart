import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/debug_context.dart';
import '../api/network_dio.dart';
import '../api/params.dart';
import '../api/openai_client.dart';
import '../api/api_failure.dart';
import '../api/error_details.dart';
import '../data/studio_store.dart';
import '../models/models.dart';
import '../plugins/plugin_registry.dart';
import 'image_download.dart';

class TaskRunner extends ChangeNotifier {
  TaskRunner(
    this.store,
    GenerationClient client, {
    Dio? downloader,
    OpenAiClient? recoveryClient,
    PluginRegistry? plugins,
  }) : client = client,
       plugins = plugins ?? (client is PluginRegistry ? client : null),
       recoveryClient = recoveryClient ?? OpenAiClient(readAsset: store.readAsset, assetLength: store.assetLength),
       downloader =
           downloader ??
           createNetworkDio(
             BaseOptions(
               followRedirects: false,
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 120),
             ),
           );
  final StudioStore store;
  final GenerationClient client;
  final OpenAiClient recoveryClient;

  /// 可选插件运行时；为空表示旧客户端，预处理/后处理步骤直接报错而不是静默跳过。
  final PluginRegistry? plugins;
  final Dio downloader;
  final Map<String, Uint8List> previews = {};
  final Set<String> _cancelled = {};
  final Map<String, CancelToken> _downloads = {};
  final Map<String, Future<void>> _active = {};
  Set<String> get activeTaskIds => Set.unmodifiable(_active.keys);
  final startedAttempts = <(String, int)>{};

  Future<String> submit(GenerationInput input) async {
    if (input.prompt.trim().isEmpty && input.references.isEmpty)
      throw const FormatException('请输入提示词或选择参考图');
    var planned = input;
    if (plugins != null) {
      planned = (await plugins!.plan(await plugins!.pinInput(input))).input;
    } else if (input.references.length > 16 ||
        input.params.count < 1 ||
        input.params.count > 10) {
      throw const FormatException('参考图最多 16 张，生成数量需为 1–10');
    }
    final provider = await _currentProvider(planned.provider.id);
    if (provider == null) throw StateError('供应商已删除或停用，请重新选择');
    if ((await store.apiKey(provider.id, baseUrl: provider.baseUrl))?.trim().isNotEmpty != true)
      throw StateError('请先配置供应商密钥');
    await store.enqueue(planned);
    unawaited(drain());
    return planned.taskId;
  }

  Future<ProviderConfig?> _currentProvider(String id) async {
    for (final provider in await store.providers()) {
      if (provider.id == id && provider.enabled) return provider;
    }
    return null;
  }

  Future<void> cancel(String id) async {
    final changed =
        await store.transition(id, TaskStatus.queued, TaskStatus.aborted) ||
        await store.transition(id, TaskStatus.running, TaskStatus.aborted);
    if (!changed) return;
    if (_active.containsKey(id)) {
      _cancelled.add(id);
      client.cancel(id);
      recoveryClient.cancel(id);
      _downloads[id]?.cancel();
    }
    previews.remove(id);
    notifyListeners();
  }

  Future<void> drain() async {
    final queued = (await store.queuedTasks()).reversed;
    for (final task in queued) {
      if (_active.containsKey(task.id)) continue;
      _active[task.id] = _run(task).whenComplete(() {
        _active.remove(task.id);
        previews.remove(task.id);
        _downloads.remove(task.id);
        _cancelled.remove(task.id);
        notifyListeners();
      });
    }
    await Future.wait(_active.values.toList());
  }

  Future<void> _run(StudioTask task) async {
    final id = task.id;
    final attempt = await store.startAttempt(id);
    if (attempt == null) return;
    startedAttempts.add((id, attempt));
    var saved = 0, position = 0;
    final checkpoints = <int, String>{};
    final savedPositions = <int>{};
    String? downloadError;
    var keepRemoteAttempt = false;
    String? failureMessage;
    final seen = <String>{};
    String? apiKey;
    notifyListeners();
    try {
      if (attempt == task.attempt) {
        checkpoints.addAll(await store.remoteCheckpoints(id, attempt));
        final outputs = await store.db.query('task_assets', columns: ['position'],
          where: "task_id = ? AND attempt = ? AND role = 'output'", whereArgs: [id, attempt]);
        savedPositions.addAll(outputs.map((row) => row['position'] as int));
        saved = savedPositions.length;
        if (checkpoints.isEmpty) throw StateError('缺少远端任务关联，无法安全恢复');
      }
      final failure = await store.pipelineFailure(id);
      // 已固定的输入是上次预处理真正发出去的内容；重跑时不再重复预处理。
      final input = await store.pinnedInput(task);
      if (failure != null && failure.stage == 'postprocess') {
        // 断点记录的是产生原始输出的那次尝试；本地重试不再调用收费生成。
        final raw = await store.attemptOutputs(id, failure.attempt);
        final expectedCount = failure.expected ?? raw.length;
        if (raw.isEmpty) throw StateError('找不到原始生成结果，无法只重跑本地处理，请重新生成');
        saved = raw.length;
        await _postprocess(
          task: task,
          input: input,
          attempt: attempt,
          failure: failure,
          expected: expectedCount,
        );
        if (!_cancelled.contains(id))
          await store.transition(
            id,
            TaskStatus.running,
            _settle(saved, expectedCount),
            error: saved < expectedCount
                ? '已保存 $saved/$expectedCount 张，服务未返回全部结果'
                : null,
          );
      } else {
        final currentProvider = await _currentProvider(input.provider.id);
        if (currentProvider == null) throw StateError('供应商已删除或停用，请重新选择');
        if (currentProvider.baseUrl != input.provider.baseUrl)
          throw StateError('供应商地址已变更，请复用参数重新提交，避免将当前密钥发送到旧地址');
        final recovering = checkpoints.isNotEmpty;
        final expectedCount = recovering && input.provider.protocol.isAsync
            ? input.params.count.clamp(1, 10)
            : plugins != null
            ? (await plugins!.plan(input)).expectedCount
            : resolveParams(
                input.params,
                protocol: input.provider.protocol,
                imageModel: input.provider.protocol != ApiProtocol.responses
                    ? input.provider.imageModel
                    : input.provider.toolModel,
                hasInputImages: input.references.isNotEmpty,
              ).count;
        final key = await store.apiKey(input.provider.id, baseUrl: input.provider.baseUrl);
        apiKey = key;
        if (key == null || key.isEmpty) throw StateError('供应商密钥缺失');
        if (_cancelled.contains(id)) return;
        final effective = recovering ? input : await _preprocess(
          task: task,
          input: input,
          attempt: attempt,
        );
        if (!identical(effective, input))
          await store.pinTaskInput(id, effective);
        // 预处理期间可能刚被取消；收费请求前再查一次，generate 会重置早期取消标记。
        if (_cancelled.contains(id)) return;
        int? nextCheckpoint;
        Stream<GenerationEvent> events() async* {
          if (!recovering) {
            yield* client.generate(effective, key);
            return;
          }
          final adapter = effective.provider.adapterId;
          if (adapter != 'wavespeed' && adapter != 'evolink') {
            throw StateError('当前适配器不支持远端恢复');
          }
          final routed = effective.copyWith(provider: ProviderConfig.fromJson({
            ...effective.provider.toJson(), 'protocol': adapter,
          }));
          final positions = checkpoints.keys.toList()..sort();
          for (var i = 0; i < positions.length; i++) {
            final start = positions[i];
            nextCheckpoint = i + 1 < positions.length ? positions[i + 1] : null;
            if (_cancelled.contains(id)) return;
            position = start;
            yield* recoveryClient.recover(routed, key, checkpoints[start]!);
          }
        }
        await for (final event in events().handleError((Object error, StackTrace stack) {
          keepRemoteAttempt = checkpoints.isNotEmpty &&
              !(error is ApiFailure && error.remoteTerminal);
          Error.throwWithStackTrace(error, stack);
        })) {
          if (_cancelled.contains(id)) break;
          if (event.kind == 'preview' && event.bytes != null) {
            previews[id] = event.bytes!;
            notifyListeners();
          } else if (event.kind == 'image') {
            if (!recovering && !effective.provider.protocol.isAsync &&
                effective.provider.adapterId != 'wavespeed' && effective.provider.adapterId != 'evolink' &&
                event.key != null && !seen.add(event.key!)) {
              continue;
            }
            final outputPosition = position++;
            if (nextCheckpoint case final boundary? when outputPosition >= boundary) {
              throw const FormatException('远端结果数量与已保存的位置不一致');
            }
            if (savedPositions.contains(outputPosition)) continue;
            Uint8List? bytes = event.bytes;
            if (bytes == null && event.url != null) {
              // 每个已计费结果都有独立位置；下载失败仍继续接收后续结果。
              await store.saveSetting('pending:$id:$attempt:$outputPosition', {
                'url': event.url,
                'mime': event.mime,
                'taskId': id,
                'attempt': attempt,
                'position': outputPosition,
              });
              try {
                bytes = await download(id, event.url!);
              } catch (error) {
                if (_cancelled.contains(id)) break;
                downloadError = safeError(error, secret: apiKey);
                continue;
              }
            }
            if (bytes == null) throw const FormatException('服务返回的图片内容为空');
            final asset = await store.saveAsset(
              bytes,
              event.mime,
              remoteUrl: event.url,
            );
            if (_cancelled.contains(id)) break;
            if (!await store.attachOutput(
              id,
              asset,
              attempt,
              outputPosition,
              requireRunning: true,
            ))
              break;
            saved++;
            savedPositions.add(outputPosition);
            await store.db.delete(
              'settings',
              where: 'key = ?',
              whereArgs: ['pending:$id:$attempt:$outputPosition'],
            );
          } else if (event.kind == 'metadata') {
            if (event is RemoteSubmission &&
                effective.provider.adapterId == event.protocol.name) {
              checkpoints[event.position] = event.remoteId;
            }
            final metadata = {...event.metadata,
              if (checkpoints.isNotEmpty) 'remote_checkpoints': {
                for (final entry in checkpoints.entries) '${entry.key}': entry.value,
              },
            };
            await store.db.update(
              'attempts',
              {'metadata': jsonEncode(metadata)},
              where: 'task_id = ? AND number = ?',
              whereArgs: [id, attempt],
            );
          }
        }
        if (!_cancelled.contains(id)) {
          if (downloadError != null)
            throw StateError(
              '已保存 $saved/$expectedCount 张，部分图片下载失败，请重新下载已有结果：$downloadError',
            );
          // 原始结果先落盘，再后处理登记派生来源；后处理失败不回滚已保存的原图。
          await _postprocess(
            task: task,
            input: input,
            attempt: attempt,
            failure: null,
            expected: expectedCount,
          );
          await store.transition(
            id,
            TaskStatus.running,
            _settle(saved, expectedCount),
            error: saved < expectedCount
                ? '已保存 $saved/$expectedCount 张，服务未返回全部结果'
                : null,
          );
        }
      }

    } catch (error) {
      if (!_cancelled.contains(id)) {
        final message = safeError(error, secret: apiKey);
        failureMessage = message;
        await store.db.update(
          'attempts',
          {'error': message},
          where: 'task_id = ? AND number = ?',
          whereArgs: [id, attempt],
        );
        await store.db.insert('errors', {
          'id': newId(),
          'task_id': id,
          'message': message,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } finally {
      if (!keepRemoteAttempt || _cancelled.contains(id)) {
        await store.db.update(
          'attempts',
          {'ended_at': DateTime.now().toUtc().toIso8601String()},
          where: 'task_id = ? AND number = ?',
          whereArgs: [id, attempt],
        );
      }
    }
    if (failureMessage != null && !_cancelled.contains(id)) {
      await store.transition(
        id, TaskStatus.running,
        saved > 0 ? TaskStatus.partialError : TaskStatus.error,
        error: failureMessage,
      );
    }
  }

  /// 完成状态只看收费原图数量，本地处理重试不改写这个契约。
  TaskStatus _settle(int saved, int expected) => saved == 0
      ? TaskStatus.error
      : saved < expected
      ? TaskStatus.partialError
      : TaskStatus.done;

  /// 预处理：只改本次实际输入，产物登记为派生资产，原参考图保持不变。
  Future<GenerationInput> _preprocess({
    required StudioTask task,
    required GenerationInput input,
    required int attempt,
  }) async {
    if (input.preprocessors.isEmpty || input.references.isEmpty) return input;
    final registry = plugins;
    if (registry == null) throw StateError('任务包含预处理步骤，当前插件运行时未加载，请重新启动后再试');
    final references = <ImageAsset>[];
    for (var i = 0; i < input.references.length; i++) {
      var image = input.references[i];
      for (final step in input.preprocessors) {
        if (_cancelled.contains(task.id)) return input;
        final result = await registry.process(
          image,
          step,
          isCancelled: () => _cancelled.contains(task.id),
        );
        if (_cancelled.contains(task.id)) return input;
        // 蒙版与标记跟第一张参考图同尺寸绑定，几何一变就拒绝，避免遮罩错位。
        if (i == 0 &&
            (input.mask != null || input.markup != null) &&
            (result.width != image.width || result.height != image.height)) {
          throw FormatException(
            '预处理「${step.processorId}」改变了带蒙版参考图的尺寸，请先去掉蒙版或关闭该步骤',
          );
        }
        await store.attachDerivedInput(task.id, result, attempt, i);
        image = result;
      }
      references.add(image);
    }
    return input.copyWith(references: references, preprocessors: const []);
  }

  /// 后处理：把每条原始输出依次交给插件，成功登记派生任务，失败记录断点供重试。
  ///
  /// 多图是有序链，某一步失败就立即结束整条链，不让后续图处理旧结果。
  Future<void> _postprocess({
    required StudioTask task,
    required GenerationInput input,
    required int attempt,
    required PipelineFailure? failure,
    required int expected,
  }) async {
    final id = task.id;
    final steps = input.postprocessors;
    if (steps.isEmpty) return;
    final registry = plugins;
    if (registry == null) throw StateError('任务包含后处理步骤，当前插件运行时未加载，请重新启动后再试');
    // 断点里保存的始终是产生原始输出那次尝试，本地重试不会读空。
    final sourceAttempt = failure?.attempt ?? attempt;
    final raw = await store.attemptOutputs(id, sourceAttempt);
    final startPosition = failure?.position ?? 0;
    if (startPosition >= raw.length)
      throw StateError('找不到原始生成结果，无法只重跑本地处理，请重新生成');
    for (var i = startPosition; i < raw.length; i++) {
      var startIndex = 0;
      var source = raw[i];
      if (failure != null && failure.position == i) {
        startIndex = failure.step;
        final previous = failure.sourceAssetId == null
            ? null
            : await store.asset(failure.sourceAssetId!);
        // 第一步的输入就是原图；更后面的步骤缺中间产物时必须明确拒绝，
        // 退回旧图或跳步都会打乱链的顺序。
        if (startIndex > 0 && previous == null)
          throw StateError(
            '第 ${i + 1} 张的中间处理结果已被清理，无法从第 ${startIndex + 1} 步继续，请重新生成',
          );
        source = previous ?? raw[i];
      }
      for (var index = startIndex; index < steps.length; index++) {
        if (_cancelled.contains(id)) return;
        final step = steps[index];
        await store.savePipelineState(
          id,
          stage: 'postprocess',
          position: i,
          attempt: sourceAttempt,
          step: index,
          sourceAssetId: source.id,
          expected: expected,
        );
        try {
          final result = await registry.process(
            source,
            step,
            isCancelled: () => _cancelled.contains(id),
          );
          if (_cancelled.contains(id)) return;
          await store.recordDerivedImage(
            source: source,
            result: result,
            step: step,
          );
          source = result;
        } catch (error) {
          if (_cancelled.contains(id)) return;
          final message = safeError(error);
          await store.savePipelineState(
            id,
            stage: 'postprocess',
            position: i,
            attempt: sourceAttempt,
            step: index,
            sourceAssetId: source.id,
            message: message,
            expected: expected,
          );
          throw StateError(
            '已保存 ${raw.length} 张原始结果；第 ${i + 1} 张「${step.processorId}」第 ${index + 1} 步失败，重试只重跑本地处理：$message',
          );
        }
      }
    }
    await store.clearPipelineState(id);
  }

  Future<Uint8List> download(String id, String url) async {
    if (_cancelled.contains(id)) throw StateError('任务已取消');
    final token = CancelToken();
    _downloads[id] = token;
    return downloadImage(url, downloader: downloader, token: token);
  }
}

String safeError(Object error, {String? secret}) {
  // 所有服务端详情都经过同一脱敏出口。
  var message = error is DioException
      ? (error.response == null
            ? '网络请求失败（${error.type.name}），请检查连接后手动重试'
            : describeApiError(
                error.response?.data,
                status: error.response?.statusCode,
              ))
      : error is FormatException
      ? error.message
      : error is StateError
      ? error.message
      : '操作失败，请检查网络与可用存储空间';
  if (error is ApiFailure &&
      error.status != null &&
      !message.contains('HTTP 状态码：'))
    message += '\nHTTP 状态码：${error.status}';
  if (secret != null && secret.isNotEmpty)
    message = message.replaceAll(secret, '[密钥已隐藏]');
  message = hideBinaryPayloads(message);
  message = message
      .replaceAllMapped(
        RegExp(r'https?://[^\s]+'),
        (match) => summarizeUrlString(match[0]!),
      )
      .replaceAll(
        RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
        'Bearer [已隐藏]',
      )
      .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]+'), '[密钥已隐藏]');
  message = message.replaceAllMapped(
    RegExp(
      r'''("(?:api[_-]?key|authorization|access_token|refresh_token|secret|token)"\s*:\s*")[^"\r\n]*(")''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[已隐藏]${match[2]}',
  );
  final detailed = message.contains('响应详情：') || message.contains('诊断信息');
  final limit = detailed ? 24000 : 500;
  if (message.length <= limit) return message;
  return message.substring(0, limit) + (limit > 500 ? '\n…（详情已截断）' : '');
}
