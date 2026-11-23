import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/studio_store.dart';
import '../../models/models.dart';
import '../../plugins/plugin_contract.dart';
import '../../plugins/plugin_manifest.dart';
import '../../plugins/plugin_registry.dart';
import '../plugins/plugin_fields_form.dart';
import 'model_input.dart';
import 'provider_detail_page.dart';

class ProviderEditorPage extends StatefulWidget {
  const ProviderEditorPage({
    super.key,
    required this.store,
    this.provider,
    this.registry,
  });

  final StudioStore store;
  final ProviderConfig? provider;

  /// 已安装的插件描述；为空时按内置协议标签回退显示。
  final PluginRegistry? registry;

  @override
  State<ProviderEditorPage> createState() => _ProviderEditorPageState();
}

class _ProviderEditorPageState extends State<ProviderEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _imageModel;
  late final TextEditingController _responseModel;
  late final TextEditingController _toolModel;
  late final TextEditingController _timeout;
  late final TextEditingController _partial;
  late final TextEditingController _safety;
  late final TextEditingController _apiKey;
  late bool _enabled;
  late bool _allowHttp;
  late ApiProtocol _protocol;
  late TransportMode _transport;
  late bool _fileInput;
  late bool _promptCompatibility;
  late String _adapterId;
  String? _adapterVersion;
  late Map<String, dynamic> _pluginConfig;
  late String _originalOrigin;
  bool _saving = false;
  String? _submitError;

  bool get _isNew => widget.provider == null;

  List<ProviderDescriptor> get _descriptors =>
      widget.registry?.providers ?? const <ProviderDescriptor>[];

  ProviderDescriptor? get _adapterDescriptor {
    for (final descriptor in _descriptors) {
      if (descriptor.id == _adapterId) return descriptor;
    }
    return null;
  }

  /// 独立插件适配器：请求协议与参数由插件自己决定，页面只渲染它声明的字段。
  bool get _independent {
    final descriptor = _adapterDescriptor;
    return descriptor != null &&
        !builtinPluginIds.contains(descriptor.pluginId);
  }

  bool get _adapterMissing =>
      widget.registry != null && _adapterDescriptor == null;

  bool get _showAdapterPicker =>
      _adapterMissing ||
      _descriptors.any(
        (descriptor) => !builtinPluginIds.contains(descriptor.pluginId),
      );

  @override
  void initState() {
    super.initState();
    final provider = widget.provider;
    _name = TextEditingController(text: provider?.name ?? '');
    _baseUrl = TextEditingController(text: provider?.baseUrl ?? '');
    _imageModel = TextEditingController(
      text: provider?.imageModel ?? 'gpt-image-1',
    );
    _responseModel = TextEditingController(
      text: provider?.responseModel ?? 'gpt-4.1',
    );
    _toolModel = TextEditingController(
      text: provider?.toolModel ?? 'gpt-image-1',
    );
    _timeout = TextEditingController(
      text: '${provider?.timeoutSeconds ?? 900}',
    );
    _partial = TextEditingController(text: '${provider?.partialImages ?? 1}');
    _safety = TextEditingController(text: provider?.safetyIdentifier ?? '');
    // 密钥从不回填，编辑时留空即保持原值。
    _apiKey = TextEditingController();
    _enabled = provider?.enabled ?? true;
    _allowHttp = provider?.allowHttp ?? false;
    _protocol = provider?.protocol ?? ApiProtocol.images;
    _transport = provider?.transport ?? TransportMode.auto;
    _fileInput = provider?.fileInput ?? false;
    _promptCompatibility = provider?.promptCompatibility ?? false;
    _adapterId = provider?.adapterId ?? _protocol.name;
    _adapterVersion = provider?.adapterVersion;
    _pluginConfig = Map<String, dynamic>.of(provider?.pluginConfig ?? const {});
    _originalOrigin = provider == null ? '' : Uri.parse(provider.baseUrl).origin;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _baseUrl,
      _imageModel,
      _responseModel,
      _toolModel,
      _timeout,
      _partial,
      _safety,
      _apiKey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value, String message) =>
      (value ?? '').trim().isEmpty ? message : null;

  String? _validateBaseUrl(String? value) {
    final uri = Uri.tryParse((value ?? '').trim());
    if (uri == null ||
        uri.host.isEmpty ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return '请输入不含凭据、查询或片段的 API 地址';
    }
    if (uri.scheme == 'http' && !_allowHttp) return '使用 HTTP 前请明确开启不安全连接';
    return null;
  }

  String? _validateInt(String? value, int min, int max, String rangeMessage) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return '请输入数字';
    final number = int.tryParse(text);
    if (number == null) return '请输入整数';
    if (number < min || number > max) return rangeMessage;
    return null;
  }

  Widget _modelField(
    String id,
    TextEditingController controller,
    String label,
  ) => ModelInput(
    fieldKey: ValueKey(id),
    controller: controller,
    label: label,
    models: widget.provider?.enabledModels ?? const [],
    onConfirmed: (_) {},
  );
  void _selectAdapter(String? id) {
    if (id == null || id == _adapterId) return;
    setState(() {
      _adapterId = id;
      final descriptor = _adapterDescriptor;
      _adapterVersion = descriptor?.version;
      if (descriptor == null) return;
      if (builtinPluginIds.contains(descriptor.pluginId)) {
        _protocol = apiProtocolByName(descriptor.id);
        if (_isNew) {
          _baseUrl.text = descriptor.defaultBaseUrl;
          _imageModel.text = descriptor.defaultModel;
        }
        return;
      }
      _pluginConfig = {
        ...pluginFieldDefaults(descriptor.fields),
        ..._pluginConfig,
      };
      if (_isNew) {
        if (_baseUrl.text.trim().isEmpty) {
          _baseUrl.text = descriptor.defaultBaseUrl;
        }
        if (_imageModel.text.trim().isEmpty ||
            _imageModel.text.trim() == 'gpt-image-1') {
          _imageModel.text = descriptor.defaultModel;
        }
      }
    });
  }

  Future<void> _copyApiKey(ProviderConfig provider) async {
    String message;
    try {
      final key = await widget.store.apiKey(
        provider.id,
        baseUrl: provider.baseUrl,
      );
      if (!mounted) return;
      if (key == null || key.isEmpty) {
        message = '此供应商尚未保存 API 密钥';
      } else {
        await Clipboard.setData(ClipboardData(text: key));
        message = 'API 密钥已复制';
      }
    } catch (_) {
      message = '复制 API 密钥失败';
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final config = ProviderConfig(
      id: widget.provider?.id ?? newId(),
      models: {
        ...?widget.provider?.enabledModels,
        if (_isNew || _imageModel.text.trim() != widget.provider?.imageModel)
          _imageModel.text.trim(),
        if (_protocol == ApiProtocol.responses) ...[
          if (_isNew ||
              _protocol != widget.provider?.protocol ||
              _responseModel.text.trim() != widget.provider?.responseModel)
            _responseModel.text.trim(),
          if (_isNew ||
              _protocol != widget.provider?.protocol ||
              _toolModel.text.trim() != widget.provider?.toolModel)
            _toolModel.text.trim(),
        ],
      }.toList(),
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      enabled: _enabled,
      allowHttp: _allowHttp,
      protocol: _protocol,
      imageModel: _imageModel.text.trim(),
      responseModel: _responseModel.text.trim(),
      toolModel: _toolModel.text.trim(),
      transport: _transport,
      fileInput: _fileInput,
      promptCompatibility: _promptCompatibility,
      timeoutSeconds: int.tryParse(_timeout.text.trim()) ?? -1,
      partialImages: int.tryParse(_partial.text.trim()) ?? -1,
      safetyIdentifier: _safety.text.trim(),
      adapterId: _adapterId,
      adapterVersion: _adapterVersion ?? _adapterDescriptor?.version,
      pluginConfig: _pluginConfig,
    );
    final descriptor = _adapterDescriptor;
    if (descriptor != null && descriptor.fields.isNotEmpty) {
      final invalidField = validatePluginFieldValues(
        descriptor.fields,
        _pluginConfig,
      );
      if (invalidField != null) {
        setState(() => _submitError = invalidField);
        return;
      }
    }
    final key = _apiKey.text.trim();
    final origin = Uri.parse(_baseUrl.text.trim()).origin;
    if (key.isEmpty && _originalOrigin.isNotEmpty && origin != _originalOrigin) {
      setState(() => _submitError = 'API 地址的主机已更改，请重新填写密钥后再保存，避免把原密钥发送到新主机。');
      return;
    }
    final invalid = config.validate();
    if (invalid != null) {
      setState(() => _submitError = invalid);
      return;
    }
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      await widget.store.saveProvider(config, key: key.isEmpty ? null : key);
      if (!mounted) return;
      if (_isNew) {
        Navigator.of(context).pushReplacement<bool, bool>(
          MaterialPageRoute(
            builder: (_) => ProviderDetailPage(
              store: widget.store,
              provider: config,
              registry: widget.registry,
              showModels: true,
            ),
          ),
          result: true,
        );
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _submitError = error is FormatException ? error.message : '保存失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? '新增供应商' : '编辑供应商')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _section(context, '基本信息'),
              _field(
                key: const ValueKey('providerName'),
                controller: _name,
                label: '名称',
                textInputAction: TextInputAction.next,
                validator: (value) => _required(value, '请输入供应商名称'),
              ),
              const SizedBox(height: 12),
              _field(
                key: const ValueKey('providerBaseUrl'),
                controller: _baseUrl,
                label: 'API 地址（Base URL）',
                helper: '保留自定义路径前缀，例如 https://host/openai/v1',
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                validator: _validateBaseUrl,
              ),
              const SizedBox(height: 12),
              _field(
                key: const ValueKey('providerApiKey'),
                controller: _apiKey,
                label: 'API 密钥',
                helper: _isNew ? '保存到系统安全存储，不会写入普通数据库' : '已保存的密钥不会显示；留空保持不变',
                obscure: true,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                suffixIcon: _isNew
                    ? null
                    : IconButton(
                        tooltip: '复制已保存的密钥',
                        onPressed: _saving
                            ? null
                            : () => _copyApiKey(widget.provider!),
                        icon: const Icon(Icons.copy_outlined),
                      ),
              ),
              if (_showAdapterPicker) ...[
                KeyedSubtree(
                  key: const ValueKey('providerAdapter'),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('providerAdapter-$_adapterId'),
                    initialValue: _adapterId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '插件适配器'),
                    items: [
                      for (final descriptor in _descriptors)
                        DropdownMenuItem(
                          value: descriptor.id,
                          child: Text(
                            '${descriptor.name}（${descriptor.pluginId} v${descriptor.version}）',
                          ),
                        ),
                      if (_adapterMissing)
                        DropdownMenuItem(
                          value: _adapterId,
                          child: Text('$_adapterId（未安装）'),
                        ),
                    ],
                    onChanged: _selectAdapter,
                  ),
                ),
                if (_adapterMissing)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '适配器「$_adapterId」未安装或未启用；保存后需安装对应插件才能生成。',
                      key: const ValueKey('providerAdapterMissing'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
              _section(context, '连接与传输'),
              if (!_independent)
                KeyedSubtree(
                  key: const ValueKey('providerProtocol'),
                  child: DropdownButtonFormField<ApiProtocol>(
                    key: ValueKey('providerProtocol-$_adapterId'),
                    initialValue: _protocol,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '协议'),
                    items: [
                      for (final protocol in ApiProtocol.values)
                        DropdownMenuItem(
                          value: protocol,
                          child: Text(
                            protocol == ApiProtocol.images
                                ? 'Images（生成 / 编辑）'
                                : protocol == ApiProtocol.responses
                                ? 'Responses（图像工具）'
                                : protocol.label,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          final previous = _protocol;
                          _protocol = value;
                          // 内置协议与内置适配器一一对应，防止协议与 adapterId 分叉。
                          _adapterId = value.name;
                          _adapterVersion = null;
                          if (_isNew &&
                              value != previous &&
                              (value.isAsync || previous.isAsync)) {
                            _baseUrl.text = switch (value) {
                              ApiProtocol.wavespeed =>
                                'https://api.wavespeed.ai/api/v3',
                              ApiProtocol.evolink =>
                                'https://api.evolink.ai/v1',
                              _ => 'https://api.openai.com/v1',
                            };
                            _imageModel.text = switch (value) {
                              ApiProtocol.wavespeed =>
                                'bytedance/seedream-v5.5/edit',
                              ApiProtocol.evolink => 'doubao-seedream-5.5',
                              _ => 'gpt-image-1',
                            };
                          }
                        });
                      }
                    },
                  ),
                ),
              const SizedBox(height: 12),
              if (!_independent && !_protocol.isAsync)
                DropdownButtonFormField<TransportMode>(
                  key: const ValueKey('providerTransport'),
                  initialValue: _transport,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '传输方式'),
                  items: const [
                    DropdownMenuItem(
                      value: TransportMode.auto,
                      child: Text('自动（auto）'),
                    ),
                    DropdownMenuItem(
                      value: TransportMode.stream,
                      child: Text('流式（stream）'),
                    ),
                    DropdownMenuItem(
                      value: TransportMode.json,
                      child: Text('JSON'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _transport = value);
                  },
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('providerEnabled'),
                contentPadding: EdgeInsets.zero,
                title: const Text('启用此供应商'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              SwitchListTile(
                key: const ValueKey('providerAllowHttp'),
                contentPadding: EdgeInsets.zero,
                title: const Text('允许 HTTP 不安全连接'),
                subtitle: const Text('仅用于明确的自托管服务'),
                value: _allowHttp,
                onChanged: (value) => setState(() => _allowHttp = value),
              ),
              const SizedBox(height: 12),
              _field(
                key: const ValueKey('providerTimeout'),
                controller: _timeout,
                label: '请求超时（秒）',
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (value) =>
                    _validateInt(value, 1, 3600, '超时需为 1–3600 秒'),
              ),
              if (_independent) ...[
                _section(context, '插件参数'),
                if (_adapterDescriptor!.fields.isEmpty)
                  const Text('该适配器未声明额外参数。')
                else
                  PluginFieldsForm(
                    key: ValueKey('pluginFields-${_adapterDescriptor!.id}'),
                    fields: _adapterDescriptor!.fields,
                    initial: _pluginConfig,
                    onChanged: (values) => _pluginConfig = values,
                  ),
              ] else ...[
                _section(context, '模型'),
                const Text('保存连接后，可在供应商模型页获取和管理启用列表。'),
                const SizedBox(height: 20),
                _modelField('providerImageModel', _imageModel, '图像模型'),
              ],
              const SizedBox(height: 20),
              if (!_independent && !_protocol.isAsync)
                _modelField(
                  'providerResponseModel',
                  _responseModel,
                  'Responses 主模型',
                ),
              const SizedBox(height: 20),
              if (!_independent && !_protocol.isAsync)
                _modelField(
                  'providerToolModel',
                  _toolModel,
                  'Responses 工具图像模型',
                ),
              if (!_independent && !_protocol.isAsync) ...[
                _section(context, '高级行为'),
                _field(
                  key: const ValueKey('providerPartialImages'),
                  controller: _partial,
                  label: '流式预览帧数（0–3）',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (value) => _validateInt(value, 0, 3, '预览帧数需为 0–3'),
                ),
                const SizedBox(height: 12),
                _field(
                  key: const ValueKey('providerSafetyIdentifier'),
                  controller: _safety,
                  label: 'Safety identifier（可选）',
                  autocorrect: false,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('providerFileInput'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Responses 图片输入使用 file_id'),
                  subtitle: const Text('关闭时以内联图片发送'),
                  value: _fileInput,
                  onChanged: (value) => setState(() => _fileInput = value),
                ),
                SwitchListTile(
                  key: const ValueKey('providerPromptCompatibility'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('提示词兼容改写'),
                  subtitle: const Text('按 Responses 兼容策略重写提示词'),
                  value: _promptCompatibility,
                  onChanged: (value) =>
                      setState(() => _promptCompatibility = value),
                ),
              ],
              if (!_independent && _protocol.isAsync)
                Text(
                  _protocol == ApiProtocol.evolink
                      ? '参考图会上传至 EvoLink 文件服务（72 小时后过期）。多张生成按数量逐次提交；停止等待后远端可能继续执行。'
                      : '参考图使用 Base64 发送，最多 10 张。多张生成按数量逐次提交；停止等待后远端可能继续执行。',
                ),
              const SizedBox(height: 8),
              Text(
                '保存后才会生效。历史任务保留原配置快照，不会自动改用其他供应商。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Material(
        color: theme.colorScheme.surface,
        elevation: 3,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_submitError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _submitError!,
                      key: const ValueKey('providerSaveError'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                FilledButton(
                  key: const ValueKey('providerSaveButton'),
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: _saving
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('保存中…'),
                          ],
                        )
                      : const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    String? helper,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
    TextInputAction? textInputAction,
    bool obscure = false,
    bool autocorrect = true,
    bool enableSuggestions = true,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      validator: validator,
      textInputAction: textInputAction,
      obscureText: obscure,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: suffixIcon,
        helperMaxLines: 2,
      ),
    );
  }
}
