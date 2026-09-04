/// 把界面上的消息下标对回 `AgentLoop.history` 里的位置。
///
/// 两个列表**不是一份东西的两个视图**，这是这个函数存在的全部理由：
///
///   - `history` 是模型看到的完整上下文；
///   - `_visible` 是界面自己维护的一份，绝大多数时候装的是同一批实例，
///     但**当前这一轮刚发出去的用户消息是个例外** —— 界面在 `_send` 里
///     自己 new 了一条，AgentLoop 在自己那边又 new 了一条。
///
/// 所以不能直接用下标。
///
/// （历史包袱：`_visible` 曾经把 tool 消息整个滤掉，两个列表长度差很多。
/// 现在工具调用画成卡片、一起进 `_visible` 了，恒等匹配几乎总能命中，
/// 下面那条按序号的兜底只剩上面那一种情况还用得上。）
library;

import '../context/overflow_manager.dart';

/// 返回 `history` 里对应的下标，找不到返回 -1。
///
/// 先按对象身份找。会话是从数据库读出来的时候，两个列表装的是同一批实例，
/// 这条路径既快又绝对准确。
///
/// **身份找不到时，只对用户消息按序号兜底。** 当前这一轮刚发出去的消息就是
/// 这种情况：界面在 `_send` 里自己 new 了一条塞进 `_visible`，而 AgentLoop
/// 在自己那边又 new 了一条塞进 `history`（它还要补检查点），两条内容一样但
/// 不是同一个对象。少了这个兜底，"编辑并重发"在**当前会话里发出的消息上
/// 永远是个空操作**——点了没反应，重开会话又好了。
///
/// 助手消息只在**两边条数相同**时才按序号兜底：条数对不上说明界面那份和
/// history 不是一一对应的，按序号猜必然错，而对不上的后果是截断到错误的
/// 位置。宁可返回 -1 让调用方放弃。
int historyIndexOfVisible(
  List<ChatMessage> visible,
  List<ChatMessage> history,
  int visibleIndex,
) {
  if (visibleIndex < 0 || visibleIndex >= visible.length) return -1;
  final target = visible[visibleIndex];

  for (var i = 0; i < history.length; i++) {
    if (identical(history[i], target)) return i;
  }

  final role = target.role;
  if (role != 'user' && role != 'assistant') return -1;

  // 助手消息只在**两边条数相同**时才按序号找。
  //
  // 一条助手气泡不一定对应 history 里的一条：工具循环里模型边说边调，
  // history 会有 assistant/tool/assistant 好几条，而界面上合并成一条。
  // 条数一致就说明没发生过合并，序号是可信的；不一致时宁可返回 -1 让
  // 调用方放弃，也不能猜——猜错的后果是把编辑写到别的消息上。
  if (role == 'assistant' &&
      _countOf(visible, 'assistant') != _countOf(history, 'assistant')) {
    return -1;
  }

  // 这是同角色的第几条。用户消息在两个列表里严格一一对应，助手消息在
  // 上面那个条件成立时也是。
  var ordinal = 0;
  for (var i = 0; i < visibleIndex; i++) {
    if (visible[i].role == role) ordinal++;
  }

  var seen = 0;
  for (var i = 0; i < history.length; i++) {
    if (history[i].role != role) continue;
    if (seen == ordinal) return i;
    seen++;
  }
  return -1;
}

int _countOf(List<ChatMessage> messages, String role) {
  var n = 0;
  for (final message in messages) {
    if (message.role == role) n++;
  }
  return n;
}

/// 摘要分隔线画在界面上第几条**之前**。**0 = 不画。**
///
/// [checkpoint] 是 `history` 的下标，而界面画的是 `visible` —— 上面那段说得
/// 很清楚，两个列表不是一份东西的两个视图。直接拿 checkpoint 当界面下标用，
/// 线就会画错位置。
///
/// 返回 0 表示"这里没有边界"，调用方必须据此**不插那一行**。这不是个可有
/// 可无的约定：0 同时也是一个合法的下标，把它当位置用就会在列表最前面插一条
/// 空的分隔行 —— 而那一行没有对应的消息，画的时候会去取 `visible[-1]`。
/// release 构建里抛异常的 widget 渲染成一块纯灰色方块，于是表现是「聊天记录
/// 上方多出一大片灰色」，看不出和摘要有任何关系。这个函数被抽出来就是为了
/// 让那件事有地方钉住。
int summaryBoundaryIndex(
  List<ChatMessage> visible,
  List<ChatMessage> history,
  int checkpoint,
) {
  if (checkpoint <= 0 || visible.isEmpty) return 0;

  // 从 checkpoint 往前找**最后一条界面上也有的**消息。history 里夹着一些
  // 只给模型看的东西（检索注入、图片描述），它们没有对应的气泡。
  //
  // 只往回找几步就放弃：注入的东西不会连着一大串，找了十几步还对不上说明
  // 两个列表已经不同步了 —— 那时候猜一个位置画条线，比不画更糟。
  final from = (checkpoint < history.length ? checkpoint : history.length) - 1;
  for (var h = from; h >= 0 && h > from - 16; h--) {
    final covered = history[h];
    for (var v = visible.length - 1; v >= 0; v--) {
      if (identical(visible[v], covered)) {
        // 线只画在中间。落在最后一条之后等于"整段对话都被摘要了"，
        // 那条线下面什么都没有，画出来只会让人以为消息没了。
        return v + 1 >= visible.length ? 0 : v + 1;
      }
    }
  }
  return 0;
}
