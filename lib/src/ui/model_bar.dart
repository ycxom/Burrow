/// 模型选择器：先选来源（渠道），再选模型。
///
/// 两类入口共用它：输入框 `+` 菜单里的「对话模型」，和设置里那张模型分工表。
/// 两者的区别只有一个 —— **选中之后要不要把当前渠道一起切走**（见
/// [showModelPicker] 的 `adoptsSource`）。对话模型必须切，因为它就是当前渠道；
/// 配角模型不能切，那正是这张表要解决的事。
///
/// ## 为什么处处标着来源
///
/// 模型名单独拿出来是**认不出花谁的钱的**：同一个模型名同时挂在一个免费
/// 网关和一个计费官方接口上，是最常见的配置，而不是什么边角情况。只显示
/// `gpt-5` 的话，用户以为在走自己的网关，实际每一轮都在扣官方额度 ——
/// 而这种事往往要等到账单出来才发现。
///
/// 所以：选择器里先选来源再选模型，每个来源下面写的是**地址**而不只是
/// 渠道名，跨来源挑模型会明说「这会把渠道一起切过去」。
library;

import 'package:flutter/material.dart';

import '../settings/channel_store.dart';
import 'chat_theme.dart';

/// 一个可选的模型来源，对应一个渠道。
class ModelSource {
  final String id;
  final String name;

  /// 地址里的 `host[:port]`。渠道名是用户自己起的，可能叫「测试」「新渠道2」，
  /// 但**花的是谁的额度由地址决定** —— 要确认"发给谁"的地方就得摆出它。
  final String host;

  /// 这个来源缓存下来的模型。空 = 还没拉过，选择器会自动拉一次。
  final List<String> models;

  /// 这个渠道自己配着的模型。
  ///
  /// 拉不动列表的来源（网关关着、地址填错）也得能选中 —— 否则"换回那个
  /// 渠道"这件事就只能绕到渠道管理里去做，而用户是在这里想起来要换的。
  final String configuredModel;

  /// 查一个模型在这个来源上的能力。
  ///
  /// 摆在选择器里而不是只留在渠道设置里：能力标错的后果（图被当没看见、
  /// 终端模式静默失效）是在**换模型的那一刻**埋下的，而这里就是那一刻。
  /// 在别处解释一百遍，不如在这里显示两个图标。
  final ResolvedCapability Function(String model)? capabilityOf;

  /// 这个来源上被标星的模型。
  ///
  /// 聚合网关一个 key 后面挂着几十上百个模型，而真正会用的就那三五个。
  /// 星标把它们提到最前面 —— 这是这个列表唯一一个"用得越久越省事"的地方。
  final Set<String> starred;

  const ModelSource({
    required this.id,
    required this.name,
    required this.host,
    this.models = const <String>[],
    this.configuredModel = '',
    this.capabilityOf,
    this.starred = const <String>{},
  });
}

/// 选择结果：在**哪个来源**上选了**哪个模型**。
///
/// 两个一起返回而不是只返回模型名：跨来源选中时，调用方要把渠道也切过去，
/// 只给模型名的话它只能安到当前渠道上 —— 那就是选错来源的那个坑本身。
class ModelChoice {
  final String sourceId;

  /// 空串 = 不启用（只有嵌入模型允许）。
  final String model;

  const ModelChoice(this.sourceId, this.model);
}

/// 模型选择弹层。
///
/// 返回选中的来源 + 模型；模型为 `''` 表示「不启用」；返回 null 表示取消。
/// 三种结果必须分开 —— 把"取消"和"不启用"混成一个，用户想关掉嵌入时
/// 反而关不掉。
Future<ModelChoice?> showModelPicker(
  BuildContext context, {
  required String title,
  required String current,
  required List<ModelSource> sources,
  required String? activeSourceId,

  /// 拉某个来源的模型列表。**带来源参数**：拉取期间用户可能已经切到别的
  /// 来源上了，不带的话拉回来的列表会安到错误的来源头上。
  required Future<List<String>> Function(String sourceId) onRefresh,

  /// 允许「不启用」。配角模型可以关，对话模型不能。
  bool allowNone = false,
  String noneLabel = '不启用',

  /// 「不启用」那一条的灰字：**关掉之后会发生什么**。
  String noneHint = '',

  /// [current] 属于哪个来源。null = 当前渠道。
  ///
  /// 分工表里挑配角模型时，"当前选的那个"完全可能在另一个渠道上 ——
  /// 不区分的话，翻到它自己那个来源时反而看不到自己的选择被打勾。
  String? currentSourceId,

  /// 选中之后把当前渠道一起切过去。
  ///
  /// 对话模型是 true（它就是当前渠道）；配角模型是 false —— 为了换个嵌入
  /// 模型把整个对话搬到另一家去，正是这张分工表存在的理由。
  bool adoptsSource = true,

  /// 标星 / 取消标星。null = 这个入口不给标星。
  ///
  /// 带来源参数：星标是**跟着渠道**的，同一个模型名在两个渠道上是两回事。
  Future<void> Function(String sourceId, String model)? onToggleStar,

  /// 上一次失败的原因。芯片上只写得下「不可用」三个字，
  /// 真正的原因得有个地方看得到 —— 否则用户只知道坏了，不知道为什么。
  String? error,
}) {
  return showModalBottomSheet<ModelChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.chat.bgPrimary,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ModelPickerSheet(
      title: title,
      current: current,
      sources: sources,
      activeSourceId: activeSourceId,
      onRefresh: onRefresh,
      allowNone: allowNone,
      noneLabel: noneLabel,
      noneHint: noneHint,
      currentSourceId: currentSourceId,
      adoptsSource: adoptsSource,
      onToggleStar: onToggleStar,
      error: error,
    ),
  );
}

class _ModelPickerSheet extends StatefulWidget {
  final String title;
  final String current;
  final List<ModelSource> sources;
  final String? activeSourceId;
  final Future<List<String>> Function(String sourceId) onRefresh;
  final bool allowNone;
  final String noneLabel;
  final String noneHint;
  final String? currentSourceId;
  final bool adoptsSource;
  final Future<void> Function(String sourceId, String model)? onToggleStar;
  final String? error;

  const _ModelPickerSheet({
    required this.title,
    required this.current,
    required this.sources,
    required this.activeSourceId,
    required this.onRefresh,
    required this.allowNone,
    required this.noneLabel,
    required this.noneHint,
    required this.currentSourceId,
    required this.adoptsSource,
    required this.onToggleStar,
    this.error,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  /// 正在看的来源。开局是**这条指派现在所在的**来源，没有就退到当前渠道 ——
  /// 用户十有八九是来换模型不是来换渠道的，而"这一项现在用的是谁"就在那里。
  late String? _sourceId = widget.currentSourceId ??
      widget.activeSourceId ??
      (widget.sources.isEmpty ? null : widget.sources.first.id);

  /// 来源 id → 模型列表。按来源分开存，切回去时不用重拉。
  late final Map<String, List<String>> _models = <String, List<String>>{
    for (final s in widget.sources) s.id: List<String>.from(s.models),
  };

  /// 拉失败的原因，同样按来源分开 —— A 拉不动不代表 B 也拉不动，
  /// 混在一起会让用户以为整个功能坏了。
  final Map<String, String> _errors = <String, String>{};

  final _filter = TextEditingController();
  final Set<String> _loading = <String>{};

  /// 用户在这个弹层里改过的星标，键是 `来源id::模型`。
  ///
  /// 存在这里而不是等外面刷新回来：标星要**当场看到**，而外面那份状态回到
  /// 这个弹层要走一整圈（写库 → notifyListeners → 上层 setState → 重建弹层），
  /// 弹层是一条独立的 route，那一圈走不到它身上。
  final Map<String, bool> _starOverrides = <String, bool>{};

  bool _isStarred(String sourceId, String model) =>
      _starOverrides['$sourceId::$model'] ??
      (widget.sources
              .where((s) => s.id == sourceId)
              .firstOrNull
              ?.starred
              .contains(model) ??
          false);

  Future<void> _toggleStar(String sourceId, String model) async {
    final toggle = widget.onToggleStar;
    if (toggle == null) return;
    setState(() {
      _starOverrides['$sourceId::$model'] = !_isStarred(sourceId, model);
    });
    await toggle(sourceId, model);
  }

  /// 标星的排到最前面，**组内保持原来的顺序**。
  ///
  /// 不做二次排序（比如按名字）：服务端返回的顺序本身带信息（不少网关把
  /// 主推的排在前面），重排一遍等于把那点信息扔了。这里只做"提到最前面"
  /// 这一件事。
  List<String> _starredFirst(String? sourceId, List<String> models) {
    if (sourceId == null) return models;
    final starred = <String>[];
    final rest = <String>[];
    for (final model in models) {
      (_isStarred(sourceId, model) ? starred : rest).add(model);
    }
    return <String>[...starred, ...rest];
  }

  ModelSource? get _source {
    for (final s in widget.sources) {
      if (s.id == _sourceId) return s;
    }
    return null;
  }

  /// 正在看的就是 [_ModelPickerSheet.current] 所属的来源。
  ///
  /// 「不启用」和「当前这个」只有在这里才该显示：在 B 的列表里点一个属于 A
  /// 的条目，选出来的到底是什么，没有一个说得通的答案。
  bool get _onCurrentSource =>
      _sourceId == (widget.currentSourceId ?? widget.activeSourceId);

  /// 在这里点下去会把当前对话渠道一起切走。
  bool get _switchesChannel =>
      widget.adoptsSource &&
      _sourceId != null &&
      _sourceId != widget.activeSourceId;

  @override
  void initState() {
    super.initState();
    final id = _sourceId;
    if (widget.error != null && id != null) _errors[id] = widget.error!;
    // 一次都没拉过就自动拉一次。让用户先看见一个空列表、再自己去点刷新，
    // 是把一个能自动做的动作推给了用户。
    if ((_models[id] ?? const <String>[]).isEmpty) _refresh();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = _sourceId;
    if (id == null || _loading.contains(id)) return;
    setState(() {
      _loading.add(id);
      _errors.remove(id);
    });
    try {
      final models = await widget.onRefresh(id);
      // 拉回来时用户可能已经切到别的来源了。按 id 存回去，不看当前选中的是谁。
      if (mounted) setState(() => _models[id] = models);
    } catch (e) {
      // 原样显示。这里的错误信息是精心拼过的（哪个候选端点返回了什么），
      // 换成"获取失败"会把唯一有用的线索丢掉。
      if (mounted) setState(() => _errors[id] = '$e');
    } finally {
      if (mounted) setState(() => _loading.remove(id));
    }
  }

  void _select(String id) {
    if (_sourceId == id) return;
    setState(() => _sourceId = id);
    if ((_models[id] ?? const <String>[]).isEmpty) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    final id = _sourceId;
    final keyword = _filter.text.trim().toLowerCase();
    final all = _models[id] ?? const <String>[];
    final matched = keyword.isEmpty
        ? all
        : all.where((m) => m.toLowerCase().contains(keyword)).toList();
    // 标过星但这次没拉回来的也要列出来：网关下架一个模型、或者列表压根没拉
    // 动的时候，用户标过的那几个仍然是他要找的东西 —— 而它们恰恰是标星唯一
    // 派得上用场的场合。
    final missing = keyword.isEmpty && id != null
        ? <String>[
            for (final model in _source?.starred ?? const <String>{})
              if (!matched.contains(model)) model,
          ]
        : const <String>[];
    final visible = _starredFirst(id, <String>[...missing, ...matched]);
    final loading = id != null && _loading.contains(id);
    final error = id == null ? null : _errors[id];

    return Padding(
      // 键盘弹起来时列表要跟着上移，否则搜索框会被自己的键盘盖住。
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.tintTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: t.tintPrimary,
                      ),
                    ),
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: '从服务端重新获取',
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                ],
              ),
            ),
            if (widget.sources.length > 1) _sourceSelector(),
            _endpointLine(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: '搜索模型',
                  filled: true,
                  fillColor: t.bgSecondary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ChatShape.radiusLg),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  error,
                  style: TextStyle(fontSize: 12, color: t.tintError),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                children: <Widget>[
                  // 「不启用」和「当前这个」都只属于这条指派所在的来源。
                  // 翻到别的来源时收起来 —— 见 [_onCurrentSource]。
                  if (widget.allowNone && _onCurrentSource)
                    _tile(
                      label: widget.noneLabel,
                      value: '',
                      selected: widget.current.isEmpty,
                      subtitle:
                          widget.noneHint.isEmpty ? null : widget.noneHint,
                    ),
                  // 当前这个不在拉回来的列表里（手填的、或者服务端换了渠道）
                  // 也要能看见自己选的是什么，否则界面上像是没选。
                  if (widget.current.isNotEmpty &&
                      _onCurrentSource &&
                      !visible.contains(widget.current) &&
                      keyword.isEmpty)
                    _tile(
                      label: widget.current,
                      value: widget.current,
                      selected: true,
                      subtitle: '手动填写，不在服务端返回的列表里',
                    ),
                  // 别的来源：把它自己配着的模型摆出来。列表拉不动的渠道
                  // （网关关着、地址填错）否则一个可点的东西都没有，
                  // 「换回那个渠道」就只能绕到渠道管理里去做。
                  if (!_onCurrentSource &&
                      (_source?.configuredModel.isNotEmpty ?? false) &&
                      !visible.contains(_source!.configuredModel) &&
                      keyword.isEmpty)
                    _tile(
                      label: _source!.configuredModel,
                      value: _source!.configuredModel,
                      selected: false,
                      subtitle: '这个渠道现在配的就是它',
                    ),
                  for (final m in visible)
                    _tile(
                      label: m,
                      value: m,
                      // 别的来源上的同名模型**不是**当前在用的那个，
                      // 打上勾会让人以为"已经是它了"从而放心点下去。
                      selected: _onCurrentSource && m == widget.current,
                    ),
                  if (visible.isEmpty && !loading && error == null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          keyword.isEmpty ? '这个渠道没有返回任何模型' : '没有匹配的模型',
                          style: TextStyle(color: t.tintTertiary),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 来源选择条。**放在模型列表上面**，而不是做成一个下拉藏起来：
  /// 「在哪个来源上挑」是选模型时一直要看得见的前提，不是一个二级选项。
  Widget _sourceSelector() {
    final t = context.chat;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          for (final s in widget.sources)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                selected: s.id == _sourceId,
                onSelected: (_) => _select(s.id),
                visualDensity: VisualDensity.compact,
                // 当前渠道加一个勾。一排芯片里总得看得出哪个是"我现在在用的"，
                // 光靠选中态说不清 —— 选中态表示的是"我正在看"。
                avatar: s.id == widget.activeSourceId
                    ? Icon(Icons.check_circle, size: 15, color: t.brand)
                    : null,
                label: Text(s.name, style: const TextStyle(fontSize: 12.5)),
              ),
            ),
        ],
      ),
    );
  }

  /// 「这次会发给谁」。地址而不是渠道名 —— 名字是用户起的，地址才是账单。
  Widget _endpointLine() {
    final t = context.chat;
    final source = _source;
    if (source == null) return const SizedBox.shrink();

    // 跨来源挑模型会连渠道一起切走，这必须在点下去**之前**说，
    // 而不是切完在状态条上闪一句 —— 那时额度已经开始花了。
    if (_switchesChannel) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: t.tintWarning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(ChatShape.radiusLg),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.swap_horiz, size: 16, color: t.tintWarning),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '在这里选模型会把当前渠道一起切到「${source.name}」，'
                '之后的对话都发往 ${source.host}',
                style: TextStyle(fontSize: 11.5, color: t.tintPrimary),
              ),
            ),
          ],
        ),
      );
    }

    // 不切渠道的入口（分工表里的配角模型）也得说一句：用户刚在一排芯片里
    // 点到了别的渠道，界面上没有任何东西说明"这不会影响我的对话"。
    final asideOfActive =
        !widget.adoptsSource && source.id != widget.activeSourceId;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.north_east, size: 13, color: t.tintTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              asideOfActive
                  ? '这一项发往 ${source.host}，当前对话渠道不变'
                  : '发往 ${source.host}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.tintTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required String label,
    required String value,
    required bool selected,
    String? subtitle,
  }) {
    final t = context.chat;
    final id = _sourceId;
    // 「不启用」那一条没有模型可言，不显示能力。
    final capability =
        value.isEmpty ? null : _source?.capabilityOf?.call(value);
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 20,
        color: selected ? t.brand : t.tintTertiary,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: t.tintPrimary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle,
              style: TextStyle(fontSize: 11, color: t.tintTertiary)),
      // 只显示**有**的能力，不显示没有的。两个灰图标并排的信息量还不如没有，
      // 而"这个模型能看图"是用户挑模型时真正在找的东西。
      trailing: value.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (capability != null) ...<Widget>[
                  if (capability.vision)
                    Tooltip(
                      message: '能直接看图',
                      child: Icon(Icons.visibility_outlined,
                          size: 16, color: t.tintTertiary),
                    ),
                  if (capability.vision && capability.tools)
                    const SizedBox(width: 6),
                  if (capability.tools)
                    Tooltip(
                      message: '支持工具调用（终端模式）',
                      child: Icon(Icons.build_outlined,
                          size: 16, color: t.tintTertiary),
                    ),
                ],
                // 星标摆在最右边，和能力图标之间留一段距离：那两个是
                // **模型的属性**（只能看），这个是**可以点的开关**。
                // 挨在一起会让人以为能力图标也能点。
                if (widget.onToggleStar != null && id != null) ...<Widget>[
                  const SizedBox(width: 10),
                  _StarButton(
                    starred: _isStarred(id, value),
                    onTap: () => _toggleStar(id, value),
                  ),
                ],
              ],
            ),
      onTap: id == null
          ? null
          : () => Navigator.pop(context, ModelChoice(id, value)),
    );
  }
}

/// 一颗可以点的星。
///
/// 单独一个 widget 而不是直接放 IconButton：它要有自己的点击热区（列表行
/// 本身是"选中这个模型"，星是另一件事），而 IconButton 默认 48 的热区会把
/// 密集列表撑高一大截。
class _StarButton extends StatelessWidget {
  const _StarButton({required this.starred, required this.onTap});

  final bool starred;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.chat;
    return Tooltip(
      message: starred ? '取消标星' : '标星，排到最前面',
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            starred ? Icons.star_rounded : Icons.star_border_rounded,
            size: 19,
            // 标了的用品牌色。没标的压到最弱一档 —— 一列全是灰星星
            // 会把真正标过的那几个淹掉。
            color: starred ? t.brand : t.tintTertiary.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}
