/// 极客设置：这个会话的采样参数。
///
/// ## 每一行都有"没设过"这个状态
///
/// 这一页和别的设置页有一处根本不同：这里的每一项都可以**不设**，而"不设"
/// 不是某个默认值，是"这个字段根本不发出去"（见 llm/sampling.dart）。
///
/// 界面必须把这件事说清楚，否则用户看到一个滑块停在 1.0 会以为"当前 top_p
/// 就是 1.0"，而实际上服务端用的是它自己那份，可能完全不是 1.0。所以每一行
/// 未设时显示的是「跟服务端默认」而不是一个数字，滑块也是灰的 —— 要先明确
/// 打开这一项，才动得了。
///
/// ## 不认的项要当场说
///
/// `top_k` 在 OpenAI 兼容层根本不存在，设了也不会发。这时候静默忽略是最糟的
/// 处理 —— 用户会以为自己调了，然后把后面所有效果的变化都归到它头上。
/// 顶部那条提示和行尾的「当前渠道不认」就是干这个的。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../llm/sampling.dart';
import 'chat_theme.dart';

class SamplingPage extends StatefulWidget {
  const SamplingPage({
    required this.initial,
    required this.apiFormat,
    required this.channelLabel,
    required this.onChanged,
    super.key,
  });

  final SamplingParams initial;

  /// 每改一项就报一次，而不是等退出这一页。
  ///
  /// 这一页没有"保存"按钮：改完退出去发一句话就能看见效果，中间再插一步
  /// 确认，只会制造"我明明改了"那一类误会 —— 而且用手势返回的人根本
  /// 按不到那个按钮。
  final ValueChanged<SamplingParams> onChanged;

  /// 当前会话那个渠道的协议。决定哪几项标成"不认"。
  final String apiFormat;

  /// 「当前渠道」在提示里的称呼。
  final String channelLabel;

  @override
  State<SamplingPage> createState() => _SamplingPageState();
}

class _SamplingPageState extends State<SamplingPage> {
  late SamplingParams _value = widget.initial;

  late final Set<SamplingKnob> _supported = knobsFor(widget.apiFormat);

  void _set(SamplingParams next) {
    setState(() => _value = next);
    widget.onChanged(next);
  }

  Future<void> _editNumber(
    SamplingKnob knob, {
    required String hint,
    required int? current,
    required int fallback,
    required int min,
    required int max,
  }) async {
    final controller =
        TextEditingController(text: (current ?? fallback).toString());
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(knob.label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
          ],
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            helperText: '$min – $max',
          ),
          onSubmitted: (text) => Navigator.pop(ctx, int.tryParse(text.trim())),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text.trim())),
            child: const Text('好'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (picked == null) return;
    // 越界就夹回去，而不是拒绝 —— 拒绝的话用户得自己猜哪个数才行。
    final clamped = picked < min ? min : (picked > max ? max : picked);
    _set(switch (knob) {
      SamplingKnob.topK => _value.copyWith(topK: clamped),
      SamplingKnob.maxTokens => _value.copyWith(maxTokens: clamped),
      SamplingKnob.seed => _value.copyWith(seed: clamped),
      _ => _value,
    });
  }

  Future<void> _editStops() async {
    final controller = TextEditingController(
      text: _value.stopSequences.join('\n'),
    );
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停止词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText: '一行一条。模型生成到其中任何一条就停下。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              controller.text
                  .split('\n')
                  .map((line) => line.trim())
                  .where((line) => line.isNotEmpty)
                  .toList(),
            ),
            child: const Text('好'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (picked == null) return;
    _set(_value.copyWith(stopSequences: picked));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final ignored = _value.ignoredBy(widget.apiFormat);
    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        title: const Text('极客设置'),
        actions: <Widget>[
          if (!_value.isEmpty)
            TextButton(
              onPressed: () => _set(SamplingParams.none),
              child: const Text('全部恢复默认'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: <Widget>[
          const _Note(
            text: '这些参数只影响这个会话。没打开的项一个字段都不会发出去，'
                '服务端用它自己的默认值。',
            tone: _NoteTone.plain,
          ),
          if (ignored.isNotEmpty)
            _Note(
              text: '${widget.channelLabel}不认这几项，设了也不会发出去：'
                  '${ignored.map((k) => k.label).join('、')}。',
              tone: _NoteTone.warn,
            ),
          _SliderRow(
            knob: SamplingKnob.topP,
            supported: _supported.contains(SamplingKnob.topP),
            value: _value.topP,
            fallback: 1,
            min: 0,
            max: 1,
            divisions: 100,
            hint: '只在概率累计到 P 的那批词里挑。调低更保守。'
                '一般和 temperature 二选一，两个一起动很难说清是谁的效果。',
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _set(_value.copyWith(topP: v)),
            onClear: () => _set(_value.clear(SamplingKnob.topP)),
          ),
          _ValueRow(
            knob: SamplingKnob.topK,
            supported: _supported.contains(SamplingKnob.topK),
            display: _value.topK?.toString(),
            hint: '每一步只在概率最高的 K 个词里挑。',
            onTap: () => _editNumber(
              SamplingKnob.topK,
              hint: '40',
              current: _value.topK,
              fallback: 40,
              min: 1,
              max: 1000,
            ),
            onClear: () => _set(_value.clear(SamplingKnob.topK)),
          ),
          _ValueRow(
            knob: SamplingKnob.maxTokens,
            supported: _supported.contains(SamplingKnob.maxTokens),
            display: _value.maxTokens?.toString(),
            hint: '一轮最多生成多少 token。设小了长回答会被截在半句。'
                '开了扩展思考时它只管答案，思考预算另算。',
            onTap: () => _editNumber(
              SamplingKnob.maxTokens,
              hint: '4096',
              current: _value.maxTokens,
              fallback: 4096,
              min: 16,
              max: 200000,
            ),
            onClear: () => _set(_value.clear(SamplingKnob.maxTokens)),
          ),
          _SliderRow(
            knob: SamplingKnob.frequencyPenalty,
            supported: _supported.contains(SamplingKnob.frequencyPenalty),
            value: _value.frequencyPenalty,
            fallback: 0,
            min: -2,
            max: 2,
            divisions: 40,
            hint: '越高越不爱重复用过的词。小模型车轱辘话多时调这个。',
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => _set(_value.copyWith(frequencyPenalty: v)),
            onClear: () => _set(_value.clear(SamplingKnob.frequencyPenalty)),
          ),
          _SliderRow(
            knob: SamplingKnob.presencePenalty,
            supported: _supported.contains(SamplingKnob.presencePenalty),
            value: _value.presencePenalty,
            fallback: 0,
            min: -2,
            max: 2,
            divisions: 40,
            hint: '越高越爱换话题。',
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => _set(_value.copyWith(presencePenalty: v)),
            onClear: () => _set(_value.clear(SamplingKnob.presencePenalty)),
          ),
          _ValueRow(
            knob: SamplingKnob.seed,
            supported: _supported.contains(SamplingKnob.seed),
            display: _value.seed?.toString(),
            // 说清"尽量"：没有哪家保证过它，说死了会让人拿它当复现工具，
            // 然后在一个本来就不保证的地方找一整天原因。
            hint: '同样的输入配同样的种子，尽量给出同样的输出。'
                '没有哪家保证这件事，只是尽量。',
            onTap: () => _editNumber(
              SamplingKnob.seed,
              hint: '42',
              current: _value.seed,
              fallback: 42,
              min: -2147483648,
              max: 2147483647,
            ),
            onClear: () => _set(_value.clear(SamplingKnob.seed)),
          ),
          _ValueRow(
            knob: SamplingKnob.stopSequences,
            supported: _supported.contains(SamplingKnob.stopSequences),
            display: _value.stopSequences.isEmpty
                ? null
                : _value.stopSequences.join(' / '),
            hint: '生成到其中任何一条就停下。',
            onTap: _editStops,
            onClear: () => _set(_value.clear(SamplingKnob.stopSequences)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

Future<void> showSamplingPage(
  BuildContext context, {
  required SamplingParams initial,
  required String apiFormat,
  required String channelLabel,
  required ValueChanged<SamplingParams> onChanged,
}) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SamplingPage(
          initial: initial,
          apiFormat: apiFormat,
          channelLabel: channelLabel,
          onChanged: onChanged,
        ),
      ),
    );

enum _NoteTone { plain, warn }

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.tone});

  final String text;
  final _NoteTone tone;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final warn = tone == _NoteTone.warn;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: warn ? t.bgErrorSecondary : t.bgSecondary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            warn ? Icons.report_outlined : Icons.info_outline,
            size: 16,
            color: warn ? t.tintError : t.tintSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: warn ? t.tintError : t.tintSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行"未设 / 已设"的开关 + 滑块。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.knob,
    required this.supported,
    required this.value,
    required this.fallback,
    required this.min,
    required this.max,
    required this.divisions,
    required this.hint,
    required this.format,
    required this.onChanged,
    required this.onClear,
  });

  final SamplingKnob knob;
  final bool supported;

  /// null = 没设过。
  final double? value;

  /// 打开这一项时从哪儿起步。
  final double fallback;
  final double min;
  final double max;
  final int divisions;
  final String hint;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final on = value != null;
    return Opacity(
      opacity: supported ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SwitchListTile(
              value: on,
              onChanged: (want) => want ? onChanged(fallback) : onClear(),
              title: Text(knob.label),
              subtitle: Text(
                _subtitle(on, supported),
                style: TextStyle(fontSize: 11, color: t.tintSecondary),
              ),
              secondary: SizedBox(
                width: 52,
                child: Text(
                  on ? format(value!) : '—',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ],
                    color: on ? t.brand : t.tintTertiary,
                  ),
                ),
              ),
            ),
            if (on)
              Slider(
                value: value!.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                hint,
                style: TextStyle(fontSize: 11, color: t.tintTertiary),
              ),
            ),
            Divider(height: 1, color: t.borderPrimary),
          ],
        ),
      ),
    );
  }

  String _subtitle(bool on, bool supported) => !supported
      ? '当前渠道不认这一项'
      : on
          ? '已设'
          : '跟服务端默认';
}

/// 一行"未设 / 已设"的开关 + 点开填个数（或一串停止词）。
class _ValueRow extends StatelessWidget {
  const _ValueRow({
    required this.knob,
    required this.supported,
    required this.display,
    required this.hint,
    required this.onTap,
    required this.onClear,
  });

  final SamplingKnob knob;
  final bool supported;

  /// null = 没设过。
  final String? display;
  final String hint;
  final Future<void> Function() onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final on = display != null;
    return Opacity(
      opacity: supported ? 1 : 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            title: Text(knob.label),
            subtitle: Text(
              !supported
                  ? '当前渠道不认这一项'
                  : on
                      ? display!
                      : '跟服务端默认',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: on ? t.brand : t.tintSecondary,
              ),
            ),
            trailing: on
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '恢复默认',
                    onPressed: onClear,
                  )
                : const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              hint,
              style: TextStyle(fontSize: 11, color: t.tintTertiary),
            ),
          ),
          Divider(height: 1, color: t.borderPrimary),
        ],
      ),
    );
  }
}
