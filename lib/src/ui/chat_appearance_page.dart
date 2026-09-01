import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/settings_store.dart';
import 'chat_theme.dart';
import 'chat_view.dart';

/// Nekogram 风格的聊天外观设置：先给一块会实时变化的对话预览，再把壁纸、
/// 暗度和头像分组放在下面。视觉设置的结果无需退出页面猜测。
class ChatAppearancePage extends StatefulWidget {
  const ChatAppearancePage({required this.store, super.key});

  final SettingsStore store;

  @override
  State<ChatAppearancePage> createState() => _ChatAppearancePageState();
}

class _ChatAppearancePageState extends State<ChatAppearancePage> {
  static const _mediaPicker = MethodChannel('com.burrow/media_picker');

  late double _previewDim = widget.store.chatWallpaperDim;
  late double _previewComposerBlur = widget.store.chatComposerBlur;
  late double _previewComposerOpacity = widget.store.chatComposerOpacity;
  final _previewComposerController = TextEditingController();
  String? _pickingSlot;

  static const _presetLabels = <ChatWallpaperPreset, String>{
    ChatWallpaperPreset.classic: '经典',
    ChatWallpaperPreset.aurora: '极光',
    ChatWallpaperPreset.sunset: '暮色',
    ChatWallpaperPreset.midnight: '深海',
  };

  Future<void> _pickImage(String slot) async {
    if (_pickingSlot != null) return;
    setState(() => _pickingSlot = slot);
    try {
      final path = await _mediaPicker.invokeMethod<String>(
        'pickImage',
        <String, String>{'slot': slot},
      );
      if (path == null || path.isEmpty) return;
      switch (slot) {
        case 'wallpaper':
          await widget.store.setChatWallpaperPath(path);
          break;
        case 'assistant_avatar':
          await widget.store.setAssistantAvatarPath(path);
          break;
        case 'user_avatar':
          await widget.store.setUserAvatarPath(path);
          break;
      }
    } on PlatformException catch (error) {
      _showError(error.message ?? '无法读取这张图片');
    } on MissingPluginException {
      _showError('当前平台不支持从相册选择图片');
    } finally {
      if (mounted) setState(() => _pickingSlot = null);
    }
  }

  Future<void> _clearImage(String slot) async {
    switch (slot) {
      case 'wallpaper':
        await widget.store.setChatWallpaperPath('');
        break;
      case 'assistant_avatar':
        await widget.store.setAssistantAvatarPath('');
        break;
      case 'user_avatar':
        await widget.store.setUserAvatarPath('');
        break;
    }
    try {
      await _mediaPicker.invokeMethod<void>(
        'clearImage',
        <String, String>{'slot': slot},
      );
    } on PlatformException {
      // 设置已经清掉。私有目录里至多留下一张会被下次选择覆盖的小图片，
      // 不值得因为清理失败阻止用户继续操作。
    } on MissingPluginException {
      // 同上；桌面预览或 widget test 没有 Android channel。
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reset() async {
    await widget.store.resetChatAppearance();
    if (mounted) {
      setState(() {
        _previewDim = 0;
        _previewComposerBlur = 20;
        _previewComposerOpacity = 0.68;
      });
    }
    for (final slot in const <String>[
      'wallpaper',
      'assistant_avatar',
      'user_avatar',
    ]) {
      try {
        await _mediaPicker.invokeMethod<void>(
          'clearImage',
          <String, String>{'slot': slot},
        );
      } catch (_) {
        // 重置视觉状态已经完成，磁盘清理是 best effort。
      }
    }
  }

  @override
  void dispose() {
    _previewComposerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('聊天外观'),
          actions: <Widget>[
            TextButton(onPressed: _reset, child: const Text('恢复默认')),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
          children: <Widget>[
            _buildPreview(),
            const SizedBox(height: 24),
            const _SectionTitle(
              icon: Icons.wallpaper_rounded,
              title: '聊天背景',
              subtitle: '选择内置配色，或使用相册中的图片',
            ),
            const SizedBox(height: 10),
            _buildPresetGrid(),
            const SizedBox(height: 10),
            _buildCustomWallpaperTile(),
            const SizedBox(height: 10),
            _buildDimCard(),
            const SizedBox(height: 24),
            const _SectionTitle(
              icon: Icons.blur_on_rounded,
              title: '输入区效果',
              subtitle: '悬浮在壁纸上的磨砂、液态玻璃或自定义材质',
            ),
            const SizedBox(height: 10),
            _buildComposerEffectCard(),
            const SizedBox(height: 24),
            const _SectionTitle(
              icon: Icons.account_circle_outlined,
              title: '头像',
              subtitle: '用于顶部身份标识与每组消息的末尾',
            ),
            const SizedBox(height: 10),
            _buildAvatarCard(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final store = widget.store;
    final t = context.chat;
    return Container(
      height: 310,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.borderPrimary),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x18000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IgnorePointer(
        child: ChatWallpaper(
          preset: store.chatWallpaperPreset,
          imagePath: store.chatWallpaperPath,
          dim: _previewDim,
          child: Column(
            children: <Widget>[
              Container(
                height: 58,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                color: t.headerBg,
                child: Row(
                  children: <Widget>[
                    ChatAvatar(
                      role: 'assistant',
                      imagePath: store.assistantAvatarPath,
                      diameter: 38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Burrow 助手',
                            style: TextStyle(
                              color: t.tintPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            '在线 · 随时可以开始',
                            style: TextStyle(
                              color: t.tintTertiary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.more_vert, color: t.tintSecondary),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      ChatBubble(
                        role: 'assistant',
                        text: '你好，今天想一起完成什么？',
                        time: DateTime(2026, 9, 1, 20, 18),
                        avatarPath: store.assistantAvatarPath,
                        showAvatar: store.showMessageAvatars,
                      ),
                      ChatBubble(
                        role: 'user',
                        text: '把聊天界面变得更舒服一些',
                        time: DateTime(2026, 9, 1, 20, 19),
                        avatarPath: store.userAvatarPath,
                        showAvatar: store.showMessageAvatars,
                      ),
                    ],
                  ),
                ),
              ),
              ChatComposer(
                controller: _previewComposerController,
                generating: false,
                enabled: true,
                hintText: '输入消息',
                onSend: () {},
                onStop: () {},
                effect: store.chatComposerEffect,
                blur: _previewComposerBlur,
                opacity: _previewComposerOpacity,
                safeAreaBottom: false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetGrid() {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.72,
      children: <Widget>[
        for (final preset in ChatWallpaperPreset.values)
          _WallpaperPresetTile(
            preset: preset,
            label: _presetLabels[preset]!,
            selected: widget.store.chatWallpaperPath.isEmpty &&
                widget.store.chatWallpaperPreset == preset,
            onTap: () => widget.store.setChatWallpaperPreset(preset),
          ),
      ],
    );
  }

  Widget _buildCustomWallpaperTile() {
    final active = widget.store.chatWallpaperPath.isNotEmpty;
    final busy = _pickingSlot == 'wallpaper';
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: context.chat.bgBrandSecondary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: busy
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.add_photo_alternate_outlined,
                  color: context.chat.brand),
        ),
        title: Text(active ? '更换自定义背景' : '从相册选择背景'),
        subtitle: Text(active ? '当前正在使用自定义图片' : '图片会复制到应用私有目录'),
        onTap: busy ? null : () => _pickImage('wallpaper'),
        trailing: active
            ? IconButton(
                tooltip: '移除自定义背景',
                onPressed: () => _clearImage('wallpaper'),
                icon: const Icon(Icons.close_rounded),
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }

  Widget _buildDimCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 8),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.brightness_6_outlined),
                const SizedBox(width: 12),
                const Expanded(child: Text('背景暗度')),
                Text(
                  '${(_previewDim * 100).round()}%',
                  style: TextStyle(
                    color: context.chat.brand,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Slider(
              value: _previewDim,
              min: 0,
              max: 0.6,
              divisions: 12,
              label: '${(_previewDim * 100).round()}%',
              onChanged: (value) => setState(() => _previewDim = value),
              onChangeEnd: widget.store.setChatWallpaperDim,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposerEffectCard() {
    final store = widget.store;
    final effect = store.chatComposerEffect;
    const labels = <ChatComposerEffect, String>{
      ChatComposerEffect.solid: '柔和实色',
      ChatComposerEffect.frosted: '悬浮磨砂',
      ChatComposerEffect.liquid: '液态玻璃',
      ChatComposerEffect.outline: '极简描边',
    };
    const icons = <ChatComposerEffect, IconData>{
      ChatComposerEffect.solid: Icons.horizontal_rule_rounded,
      ChatComposerEffect.frosted: Icons.blur_on_rounded,
      ChatComposerEffect.liquid: Icons.water_drop_outlined,
      ChatComposerEffect.outline: Icons.radio_button_unchecked_rounded,
    };
    final description = switch (effect) {
      ChatComposerEffect.solid => '稳定清晰的半透明实色，适合复杂壁纸',
      ChatComposerEffect.frosted => '均匀模糊背后的壁纸，像一块悬浮磨砂玻璃',
      ChatComposerEffect.liquid => '带高光、折射渐变与柔和光晕的液态材质',
      ChatComposerEffect.outline => '只保留轻微模糊与品牌色轮廓，最轻盈',
    };

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                for (final value in ChatComposerEffect.values)
                  ChoiceChip(
                    avatar: Icon(icons[value], size: 17),
                    label: Text(labels[value]!),
                    selected: effect == value,
                    onSelected: (_) => store.setChatComposerEffect(value),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
              child: Text(
                description,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const Divider(height: 18),
            _AppearanceSlider(
              icon: Icons.blur_circular_outlined,
              label: '模糊强度',
              valueLabel: '${_previewComposerBlur.round()}',
              value: _previewComposerBlur,
              min: 0,
              max: 30,
              divisions: 15,
              enabled: effect != ChatComposerEffect.solid,
              onChanged: (value) =>
                  setState(() => _previewComposerBlur = value),
              onChangeEnd: store.setChatComposerBlur,
            ),
            _AppearanceSlider(
              icon: Icons.opacity_rounded,
              label: '材质不透明度',
              valueLabel: '${(_previewComposerOpacity * 100).round()}%',
              value: _previewComposerOpacity,
              min: 0.25,
              max: 1,
              divisions: 15,
              onChanged: (value) =>
                  setState(() => _previewComposerOpacity = value),
              onChangeEnd: store.setChatComposerOpacity,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarCard() {
    final store = widget.store;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _AvatarTile(
            role: 'assistant',
            imagePath: store.assistantAvatarPath,
            title: '助手头像',
            subtitle: store.assistantAvatarPath.isEmpty ? '使用默认星光图标' : '自定义图片',
            busy: _pickingSlot == 'assistant_avatar',
            onTap: () => _pickImage('assistant_avatar'),
            onClear: store.assistantAvatarPath.isEmpty
                ? null
                : () => _clearImage('assistant_avatar'),
          ),
          const Divider(height: 1),
          _AvatarTile(
            role: 'user',
            imagePath: store.userAvatarPath,
            title: '我的头像',
            subtitle: store.userAvatarPath.isEmpty ? '使用默认人物图标' : '自定义图片',
            busy: _pickingSlot == 'user_avatar',
            onTap: () => _pickImage('user_avatar'),
            onClear: store.userAvatarPath.isEmpty
                ? null
                : () => _clearImage('user_avatar'),
          ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.forum_outlined),
            title: const Text('显示消息头像'),
            subtitle: const Text('只在每组连续消息的最后一条显示'),
            value: store.showMessageAvatars,
            onChanged: store.setShowMessageAvatars,
          ),
        ],
      ),
    );
  }
}

class _WallpaperPresetTile extends StatelessWidget {
  const _WallpaperPresetTile({
    required this.preset,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ChatWallpaperPreset preset;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? t.brand : t.borderPrimary,
              width: selected ? 2 : 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(selected ? 13.5 : 15),
            child: ChatWallpaper(
              preset: preset,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.48),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  if (selected)
                    const Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircleAvatar(
                          radius: 10,
                          child: Icon(Icons.check_rounded, size: 14),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AvatarTile extends StatelessWidget {
  const _AvatarTile({
    required this.role,
    required this.imagePath,
    required this.title,
    required this.subtitle,
    required this.busy,
    required this.onTap,
    this.onClear,
  });

  final String role;
  final String imagePath;
  final String title;
  final String subtitle;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          ChatAvatar(role: role, imagePath: imagePath, diameter: 50),
          if (busy)
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.38),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(15),
              child: const CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
        ],
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: busy ? null : onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (onClear != null)
            IconButton(
              tooltip: '恢复默认头像',
              onPressed: busy ? null : onClear,
              icon: const Icon(Icons.close_rounded),
            ),
          Icon(Icons.edit_outlined, color: context.chat.tintSecondary),
        ],
      ),
    );
  }
}

class _AppearanceSlider extends StatelessWidget {
  const _AppearanceSlider({
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final tint = enabled ? context.chat.tintPrimary : context.chat.tintTertiary;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 20, color: tint),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: TextStyle(color: tint))),
              Text(
                valueLabel,
                style: TextStyle(
                  color:
                      enabled ? context.chat.brand : context.chat.tintTertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: context.chat.bgBrandSecondary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: context.chat.brand, size: 21),
        ),
        const SizedBox(width: 11),
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
    );
  }
}
