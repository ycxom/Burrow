import 'package:flutter/material.dart';

import '../llm/llm_client.dart';
import '../settings/settings_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.store,
    required this.client,
    super.key,
  });

  final SettingsStore store;
  final ConfigurableLlmClient client;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ProviderPreset _provider;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _model;
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
                  if (_provider.models.isNotEmpty) ...<Widget>[
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
              children: const [
                ListTile(
                  leading: Icon(Icons.shield_outlined),
                  title: Text('沙箱模式'),
                  subtitle: Text('命令限制在当前任务工作区，高风险操作需要确认'),
                  trailing: Icon(Icons.chevron_right),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.folder_outlined),
                  title: Text('默认工作目录'),
                  subtitle: Text('每个任务使用独立 workspace'),
                  trailing: Icon(Icons.chevron_right),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.history),
                  title: Text('上下文与检查点'),
                  subtitle: Text('长对话自动摘要，文件修改可回滚'),
                  trailing: Icon(Icons.chevron_right),
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
