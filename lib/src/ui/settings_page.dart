import 'dart:io';

import 'package:flutter/material.dart';

import '../agent/agent_loop.dart';
import '../context/overflow_manager.dart';
import '../sandbox/sandbox_session.dart';
import '../sandbox/snapshot_store.dart';
import '../settings/account_store.dart';
import '../settings/channel_store.dart';
import '../llm/vision.dart';
import 'system_prompt_page.dart';
import '../settings/settings_store.dart';
import 'agent_settings_page.dart';
import 'chat_appearance_page.dart';
import 'channels_page.dart';
import 'skin_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.store,
    required this.channels,
    required this.accounts,
    required this.capabilities,
    required this.tasksRoot,
    required this.currentTaskId,
    required this.overflow,
    required this.snapshots,
    required this.skins,
    super.key,
  });

  final SettingsStore store;

  /// 渠道列表。接入点、认证、代理全在这里改 —— 设置页只做入口。
  final ChannelStore channels;

  /// OAuth 账号。它们现在归渠道管理，设置页只负责把两者一起传下去。
  final AccountStore accounts;

  // 下面这几个是「Agent 与终端」那三个子页要用的运行时对象。
  // 设置页自己不碰它们，只负责往下传。
  final SandboxCapabilities capabilities;
  final Directory tasksRoot;
  final String currentTaskId;
  final OverflowManager overflow;
  final SnapshotStore snapshots;

  /// 只为传给外观页。设置页自己不碰皮肤。
  final ChatSkinStore skins;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late double _temperature = widget.store.temperature;
  late bool _streamOutput = widget.store.streamOutput;

  /// 子页改的是同一批 store，回来时要重建 —— 否则列表里的副标题
  /// 还停在旧值上，看起来像"改了没生效"。
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

  /// 当前渠道那一行的副标题。把「发给谁、用什么认证、走不走代理」压成一行 ——
  /// 这三件事任何一个不对，表现都是同一种"连不上"，放在一起才看得出是哪个。
  String _channelSummary() {
    final channel = widget.channels.active;
    if (channel == null) return '还没有渠道，点这里新建';
    final bits = <String>[
      channel.baseUrl.isEmpty ? '未填地址' : channel.baseUrl,
      if (channel.model.isNotEmpty) channel.model,
      if (channel.usesOAuth)
        'OAuth'
      else if (widget.channels.apiKeyOf(channel).isEmpty)
        '未填密钥',
      if (channel.proxy?.isNotEmpty ?? false) '代理',
    ];
    return bits.join(' · ');
  }

  Future<void> _editSystemPrompt() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SystemPromptPage(
        title: '全局系统提示词',
        initial: widget.store.systemPrompt,
        onSave: widget.store.setSystemPrompt,
      ),
    ));
    if (mounted) setState(() {});
  }

  String _imageModeSummary() =>
      _imageModeSummaryFor(widget.store, widget.channels);

  Future<void> _pickImageMode() async {
    const labels = <ImageMode, (String, String)>{
      ImageMode.auto: ('自动', '渠道勾了「能看图」就直发，否则先描述'),
      ImageMode.native: ('总是直接发图', '模型不认图的话会报错 —— 但报错来自服务端，比这里拦下来更有信息量'),
      ImageMode.preprocess: (
        '总是先描述',
        '即使对话模型认图也先描述。用便宜的视觉模型看一次，比让旗舰模型每轮重读一张图便宜'
      ),
    };
    final picked = await showModalBottomSheet<ImageMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final entry in labels.entries)
              ListTile(
                leading: Icon(
                  entry.key == widget.store.imageMode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(entry.value.$1),
                subtitle:
                    Text(entry.value.$2, style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, entry.key),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      await widget.store.setImageMode(picked);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          const _Header(
            icon: Icons.palette_outlined,
            title: '聊天外观',
            subtitle: '壁纸、背景暗度与消息头像',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.wallpaper_rounded),
              title: const Text('现代聊天界面'),
              subtitle: Text(
                widget.store.chatWallpaperPath.isNotEmpty
                    ? '自定义背景 · 头像与气泡预览'
                    : '内置背景 · 头像与气泡预览',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(
                ChatAppearancePage(store: widget.store, skins: widget.skins),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const _Header(
            icon: Icons.hub_outlined,
            title: '渠道',
            subtitle: '发给谁、用什么认证、走不走代理',
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(widget.channels.active?.name ?? '渠道管理'),
              subtitle: Text(_channelSummary()),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _push(ChannelsPage(
                channels: widget.channels,
                accounts: widget.accounts,
              )),
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
                  onChanged: (value) {
                    setState(() => _streamOutput = value);
                    widget.store.setStreamOutput(value);
                  },
                ),
                const Divider(height: 1),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: const Text('系统提示词'),
                  subtitle: Text(
                    widget.store.systemPrompt.trim().isEmpty
                        ? '没设，只用内置那份'
                        : widget.store.systemPrompt
                            .trim()
                            .replaceAll('\n', ' '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editSystemPrompt,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.image_outlined),
                  title: const Text('图片怎么发'),
                  subtitle: Text(
                    _imageModeSummary(),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickImageMode,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.thermostat_outlined),
                  title:
                      Text('Temperature  ${_temperature.toStringAsFixed(1)}'),
                  subtitle: Slider(
                    value: _temperature,
                    min: 0,
                    // Anthropic 的上界是 1，OpenAI 兼容是 2。跟着当前渠道走 ——
                    // 拿另一套的上界去限，滑到一半就被截断。
                    max: widget.channels.active?.apiFormat == 'anthropic'
                        ? 1
                        : 2,
                    divisions: widget.channels.active?.apiFormat == 'anthropic'
                        ? 10
                        : 20,
                    onChanged: (value) => setState(() => _temperature = value),
                    onChangeEnd: widget.store.setTemperature,
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

/// 图片模式那一行的副标题：**说清楚现在会发生什么**，而不是复述选项名。
///
/// 「自动」这三个字本身不含任何信息 —— 用户想知道的是"我现在附一张图，
/// 它会走哪条路"，而那取决于当前渠道勾没勾"能看图"。
String _imageModeSummaryFor(SettingsStore store, ChannelStore channels) {
  final capable = channels.active?.visionCapable ?? false;
  final hasVision = channels.channels.any((c) => c.canDescribeImages);
  return switch (store.imageMode) {
    ImageMode.native => '总是直接发给对话模型',
    ImageMode.preprocess =>
      hasVision ? '总是先用视觉模型描述成文字，再发给对话模型' : '总是先描述 —— 但还没有任何渠道配了视觉模型',
    ImageMode.auto => capable
        ? '当前渠道勾了「能看图」，会直接发'
        : hasVision
            ? '当前渠道不认图，会先用视觉模型描述一遍'
            : '当前渠道不认图，也没有渠道配了视觉模型 —— 现在发不了图',
  };
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
