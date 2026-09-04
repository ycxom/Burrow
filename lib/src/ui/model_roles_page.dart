/// 模型分工表：哪件事用**哪个渠道的哪个模型**。
///
/// ## 为什么要有这一页
///
/// 在它之前，除了对话模型以外的模型只有一个**名字**，地址和密钥现取当前
/// 渠道的。于是「聊天用 A、嵌入用 B、图片转文字用 C」这个再正常不过的组合
/// 根本配不出来 —— 想用 B 的嵌入模型，就得把整个对话也搬到 B 上去。
///
/// 而且它不报错：在 B 的模型列表里挑一个嵌入模型，程序照样拿这个名字去 A
/// 的地址上请求。所以这一页的每一行都必须把**渠道**一起显示出来 ——
/// 光有模型名的那个界面，正是上面那个坑的成因。
library;

import 'package:flutter/material.dart';

import '../settings/account_store.dart';
import '../settings/channel_store.dart';
import '../settings/model_roles.dart';
import '../settings/settings_store.dart';
import 'model_bar.dart';
import 'model_sources.dart';

class ModelRolesPage extends StatefulWidget {
  const ModelRolesPage({
    required this.channels,
    required this.settings,
    required this.accounts,
    this.embeddingError,
    super.key,
  });

  final ChannelStore channels;
  final SettingsStore settings;
  final AccountStore accounts;

  /// 嵌入那一路最近一次失败的原因。
  ///
  /// 是个闭包而不是一个值：它在会话跑着的时候才会变，而这一页可能开着不动。
  /// 取快照的话，用户改完配置回到这一页看到的还是上一次的错误。
  final String? Function()? embeddingError;

  @override
  State<ModelRolesPage> createState() => _ModelRolesPageState();
}

class _ModelRolesPageState extends State<ModelRolesPage> {
  late final ModelSourceCatalog _catalog = ModelSourceCatalog(
    channels: widget.channels,
    accounts: widget.accounts,
    settings: widget.settings,
  );

  Future<void> _pick(ModelRole role) async {
    final current = widget.channels.refOf(role);
    final picked = await showModelPicker(
      context,
      title: role.label,
      current: current?.model ?? '',
      currentSourceId: current?.channelId,
      sources: _catalog.sources(),
      activeSourceId: widget.channels.activeId,
      onRefresh: _catalog.refresh,
      allowNone: role.optional,
      noneLabel: role.unsetLabel,
      noneHint: role.hint,
      // 对话模型就是当前渠道，选中它必须把渠道一起切走；配角模型反过来
      // —— 为了换个嵌入模型把整个对话搬到另一家去，正是这一页要根治的事。
      adoptsSource: role == ModelRole.chat,
      error: role == ModelRole.embedding ? widget.embeddingError?.call() : null,
    );
    if (picked == null) return;
    await widget.channels.assignRole(
      role,
      picked.model.isEmpty
          ? null
          : ModelRef(channelId: picked.sourceId, model: picked.model),
    );
    if (mounted) setState(() {});
  }

  /// 一行的灰字：**现在这一项到底会发生什么**。
  ///
  /// 只写模型名是不够的 —— 同一个模型名同时挂在一个免费网关和一个计费官方
  /// 接口上是最常见的配置，而花的是谁的额度由渠道决定。
  String _summary(ModelRole role) {
    final resolved = widget.channels.resolveRole(role);
    if (resolved == null) {
      return switch (role) {
        ModelRole.chat => '还没配对话模型 —— 现在什么都发不出去',
        ModelRole.embedding => '不启用 · 记忆检索只用 BM25 + 覆盖率两路词法',
        ModelRole.vision => '跟随渠道设置 · 从配了视觉模型的渠道里挑一个',
        ModelRole.summary => '跟随对话渠道',
      };
    }
    final where = '${resolved.channel.name} · ${resolved.model}';
    return resolved.inherited ? '$where（跟随对话渠道）' : where;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('模型分工')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              '每一项各自指定渠道和模型。聊天走 A、嵌入走 B、'
              '图片转文字走 C 是允许的 —— 每一项都发往它自己那个渠道。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (widget.channels.channels.isEmpty)
            Card(
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                leading: Icon(Icons.error_outline, color: scheme.error),
                title: const Text('还没有任何渠道'),
                subtitle: const Text('先到「渠道管理」里加一个接入点，'
                    '这一页才有东西可挑'),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (final role in ModelRole.values) ...<Widget>[
                    if (role != ModelRole.values.first)
                      const Divider(height: 1),
                    _RoleTile(
                      role: role,
                      summary: _summary(role),
                      warning: _warningFor(role),
                      onTap: () => _pick(role),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '「跟随」表示这一项没单独指定，跟着当前对话渠道走 —— '
            '换了对话渠道它也会跟着换。',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 这一行现在有没有配坏的东西。
  ///
  /// 两类：**协议对不上**（嵌入和摘要走的是写死的 OpenAI 兼容端点，指到
  /// Anthropic / Gemini 原生渠道上会一直不工作），和**这一路真的报过错**。
  /// 两者的共同点是它们都不会让用户看到任何异常 —— 只是安静地少一块功能。
  String? _warningFor(ModelRole role) {
    final resolved = widget.channels.resolveRole(role);
    if (resolved == null) return null;
    if (role == ModelRole.embedding) {
      final error = widget.embeddingError?.call();
      if (error != null) return '不可用：$error';
    }
    return roleProtocolWarning(role, resolved.channel.apiFormat);
  }
}

class _RoleTile extends StatelessWidget {
  const _RoleTile({
    required this.role,
    required this.summary,
    required this.warning,
    required this.onTap,
  });

  final ModelRole role;
  final String summary;
  final String? warning;
  final VoidCallback onTap;

  static IconData _icon(ModelRole role) => switch (role) {
        ModelRole.chat => Icons.auto_awesome,
        ModelRole.embedding => Icons.hub_outlined,
        ModelRole.vision => Icons.image_search_outlined,
        ModelRole.summary => Icons.compress,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(_icon(role)),
      title: Text(role.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          Text(role.hint, style: const TextStyle(fontSize: 11)),
          if (warning case final text?)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 13, color: scheme.error),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
