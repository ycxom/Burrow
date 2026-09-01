import 'dart:io';

import 'package:flutter/material.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../llm/llm_client.dart';
import '../llm/model_catalog.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../settings/account_store.dart';
import '../settings/settings_store.dart';
import 'agent_settings_page.dart';
import 'chat_theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.store,
    required this.client,
    required this.accounts,
    required this.capabilities,
    required this.tasksRoot,
    required this.currentTaskId,
    required this.overflow,
    required this.snapshots,
    super.key,
  });

  final SettingsStore store;
  final ConfigurableLlmClient client;

  /// 已登录的 OAuth 账号。设置页要能把 baseUrl / key 一键切成订阅账号。
  final AccountStore accounts;

  // 下面这几个是「Agent 与终端」那三个子页要用的运行时对象。
  // 设置页自己不碰它们，只负责往下传。
  final SandboxCapabilities capabilities;
  final Directory tasksRoot;
  final String currentTaskId;
  final OverflowManager overflow;
  final SnapshotStore snapshots;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProviderPreset _provider;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;

  /// 从服务端拉回来的模型列表。null = 还没拉过（这时只显示预设里的几个）。
  List<FetchedModel>? _fetchedModels;
  bool _fetchingModels = false;
  String? _modelFetchError;
  late final TextEditingController _summaryModel;
  late double _temperature;
  late bool _streamOutput;
  bool _obscure = true;
  bool _saving = false;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final config = widget.store.config;
    _provider = providerPresets.firstWhere(
      (preset) => preset.name == widget.store.provider,
      orElse: () => providerPresets.first,
    );
    _url = TextEditingController(text: config.baseUrl);
    _key = TextEditingController(text: config.apiKey);
    _model = TextEditingController(text: config.model);
    _summaryModel = TextEditingController(text: config.summaryModel ?? '');
    _temperature = config.temperature;
    _streamOutput = config.streamOutput;
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _model.dispose();
    _summaryModel.dispose();
    super.dispose();
  }

  /// 子页改的是同一个 SettingsStore，回来时要重建 —— 否则上面那几行
  /// 副标题还停在旧值上，看起来像"改了没生效"。
  Future<void> _push(Widget page) async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) setState(() {});
  }

  static String _levelName(SandboxLevel level) => switch (level) {
        SandboxLevel.readOnly => '只读',
        SandboxLevel.workspaceWrite => '工作区可写',
        SandboxLevel.workspaceWriteNetwork => '工作区可写 + 联网',
        SandboxLevel.dangerFullAccess => '已关闭沙箱',
      };

  static String _approvalName(ApprovalMode mode) => switch (mode) {
        ApprovalMode.readOnly => '只读',
        ApprovalMode.onRequest => '按需审批',
        ApprovalMode.auto => '自动执行',
        ApprovalMode.yolo => '不审批',
      };

  void _select(ProviderPreset value) {
    setState(() {
      _provider = value;
      _url.text = value.baseUrl;
      if (value.models.isNotEmpty) _model.text = value.models.first;
      if (value.apiFormat == 'anthropic' && _temperature > 1) {
        _temperature = 1;
      }
    });
  }

  void _selectFormat(String format) {
    final preset = providerPresets.firstWhere(
      (item) => item.apiFormat == format,
      orElse: () => providerPresets.first,
    );
    _select(preset);
  }

  LlmConfig _draft() => LlmConfig(
        apiFormat: _provider.apiFormat,
        baseUrl: _url.text.trim(),
        apiKey: _key.text.trim(),
        model: _model.text.trim(),
        summaryModel: _summaryModel.text.trim().isEmpty
            ? null
            : _summaryModel.text.trim(),
        temperature: _temperature,
        streamOutput: _streamOutput,
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = _draft();
    await widget.store.save(provider: _provider.name, config: config);
    widget.client.config = config;
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('模型配置已保存，API Key 已写入安全存储')),
    );
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    String message;
    try {
      await widget.client.testConnection(_draft());
      message = '连接成功：${_provider.name} · ${_model.text.trim()}';
    } catch (error) {
      message = error is LlmConnectionException ? error.message : '测试失败：$error';
    }
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _fetchModels() async {
    setState(() {
      _fetchingModels = true;
      _modelFetchError = null;
    });
    try {
      final models = await fetchModels(
        baseUrl: _url.text.trim(),
        apiKey: _key.text.trim(),
      );
      if (mounted) setState(() => _fetchedModels = models);
    } catch (e) {
      // 把失败原因原样显示。这里的错误信息是精心拼过的（哪个候选端点
      // 返回了什么），截断或者换成"获取失败"会把唯一有用的线索丢掉。
      if (mounted) setState(() => _modelFetchError = '$e');
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  /// 用一个已登录的订阅账号填上 baseUrl 和协议。
  ///
  /// key 留空 —— 订阅账号走 Bearer access_token，那个 token 会过期，
  /// 抄进输入框就等于抄了一份马上失效的副本。运行时从 AccountStore 现取。
  void _useAccount(String providerId) {
    final provider = widget.accounts.providerById(providerId);
    if (provider == null) return;
    setState(() {
      _url.text = provider.apiBaseUrl;
      _key.text = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: <Widget>[
          TextButton(
              onPressed: _saving ? null : _save, child: const Text('保存')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          const _Header(
            icon: Icons.smart_toy_outlined,
            title: '模型服务',
            subtitle: '聊天和 Agent 共用同一个模型配置',
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'openAI',
                          icon: Icon(Icons.check),
                          label: Text('OpenAI'),
                        ),
                        ButtonSegment(
                          value: 'anthropic',
                          icon: Icon(Icons.chat_outlined),
                          label: Text('Anthropic'),
                        ),
                      ],
                      selected: {_provider.apiFormat},
                      onSelectionChanged: (value) => _selectFormat(value.first),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ProviderPreset>(
                    initialValue: _provider,
                    decoration: const InputDecoration(
                      labelText: '服务商',
                      prefixIcon: Icon(Icons.cloud_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: providerPresets
                        .map((preset) => DropdownMenuItem(
                              value: preset,
                              child: Text(preset.name),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) _select(value);
                    },
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Text(
                        _provider.apiFormat == 'anthropic'
                            ? 'Anthropic Messages 协议'
                            : '${_provider.name} 接口',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      prefixIcon: const Icon(Icons.key_outlined),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(_obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _model,
                    decoration: const InputDecoration(
                      labelText: '主模型',
                      prefixIcon: Icon(Icons.memory),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: _fetchingModels ? null : _fetchModels,
                        icon: _fetchingModels
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.cloud_download_outlined,
                                size: 18),
                        label: Text(_fetchingModels ? '获取中…' : '从服务端获取模型'),
                      ),
                    ],
                  ),
                  if (_modelFetchError != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: context.chat.bgErrorSecondary,
                        borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                        border: Border.all(color: context.chat.tintError),
                      ),
                      child: SelectableText(
                        _modelFetchError!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                  // 拉回来的排在前面，预设的作为兜底 ——
                  // 真实列表永远比我们硬编码的那几个准。
                  if ((_fetchedModels ?? const []).isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text('服务端返回 ${_fetchedModels!.length} 个模型',
                        style: const TextStyle(fontSize: 11)),
                    const SizedBox(height: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: _fetchedModels!
                              .map((m) => ActionChip(
                                    label: Text(m.id,
                                        style: const TextStyle(fontSize: 12)),
                                    onPressed: () =>
                                        setState(() => _model.text = m.id),
                                  ))
                              .toList(),
                        ),
                      ),
                    ),
                  ] else if (_provider.models.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        children: _provider.models
                            .map((model) => ActionChip(
                                  label: Text(model),
                                  onPressed: () =>
                                      setState(() => _model.text = model),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                  if (widget.accounts.signedIn.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        children: widget.accounts.signedIn
                            .map((p) => ActionChip(
                                  avatar: const Icon(Icons.account_circle,
                                      size: 16),
                                  label: Text('用 ${p.displayName}',
                                      style: const TextStyle(fontSize: 12)),
                                  onPressed: () => _useAccount(p.id),
                                ))
                            .toList(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _summaryModel,
                    decoration: const InputDecoration(
                      labelText: '摘要模型（可选）',
                      helperText: '长对话压缩可使用更便宜的小模型',
                      prefixIcon: Icon(Icons.compress),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check),
                      label: Text(_testing ? '测试中…' : '测试连接'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const _Header(
            icon: Icons.tune,
            title: '生成参数',
            subtitle: 'Burrow 会为终端输出预留额外上下文',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.stream),
                  title: const Text('流式输出'),
                  subtitle: const Text('生成内容实时显示，Markdown 平滑刷新'),
                  value: _streamOutput,
                  onChanged: (value) => setState(() => _streamOutput = value),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.thermostat_outlined),
                  title:
                      Text('Temperature  ${_temperature.toStringAsFixed(1)}'),
                  subtitle: Slider(
                    value: _temperature,
                    min: 0,
                    max: _provider.apiFormat == 'anthropic' ? 1 : 2,
                    divisions: _provider.apiFormat == 'anthropic' ? 10 : 20,
                    onChanged: (value) => setState(() => _temperature = value),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _Header(
            icon: Icons.shield_outlined,
            title: 'Agent 与终端',
            subtitle: '控制本地命令的执行边界',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('沙箱模式'),
                  // 副标题显示当前档位而不是一句固定的介绍 ——
                  // 设置项的当前值应该在列表里就看得见，不用点进去猜。
                  subtitle: Text(
                    '${_levelName(widget.store.sandboxLevel)}'
                    ' · ${_approvalName(widget.store.approvalMode)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(SandboxSettingsPage(
                    store: widget.store,
                    capabilities: widget.capabilities,
                  )),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('默认工作目录'),
                  subtitle: const Text('每个会话使用独立 workspace，可查看占用并清理'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(WorkspaceSettingsPage(
                    tasksRoot: widget.tasksRoot,
                    currentTaskId: widget.currentTaskId,
                  )),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('上下文与检查点'),
                  subtitle: Text(
                    '超过 ${widget.store.messageThreshold} 条或 '
                    '${widget.store.tokenThreshold} token 自动摘要',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _push(ContextSettingsPage(
                    store: widget.store,
                    overflow: widget.overflow,
                    snapshots: widget.snapshots,
                  )),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'API Key 保存在设备安全区域。模型可调用终端和文件工具，写入与高风险命令仍受审批和检查点保护。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(
      {required this.icon, required this.title, required this.subtitle});

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Row(
          children: <Widget>[
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      );
}
