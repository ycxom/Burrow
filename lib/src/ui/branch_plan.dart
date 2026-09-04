/// 分支点选在哪一条上。
///
/// ## 「前一条」，不是「最后一条问话」
///
/// 重新生成一条回复时，要被替换的是**它和它之后的一切**，所以分支锚点是它
/// 前面那一条。以前这里写的是"最后一条用户消息"，那在最简单的一问一答里
/// 恰好等价，但只要出现下面任何一种情况就错：
///
///   - 一轮里模型说了好几段（`assistant → assistant`）：重新生成第二段
///     应该只换第二段，锚在用户那条会把第一段也一起丢掉。
///   - 工具循环（`assistant → tool → assistant`）：重新生成最后那条答案
///     应该保留已经跑出来的工具结果，锚在用户那条等于让模型把命令重跑一遍。
///   - 想重新生成**中间**某一条：以前根本做不到，只有最后一条能重来。
///
/// ## 哪些消息能当锚点
///
/// 只有用户、助手、工具这三种是"对话里真实存在过"的。history 里还夹着一些
/// 每轮现算、只给模型看的东西（检索注入、图片描述）—— 它们下一轮就换内容了，
/// 把分支锚在上面，切回来的时候那条锚点已经不是同一句话了。
library;

import '../context/overflow_manager.dart';

/// 能当分支锚点的角色。
bool _anchorable(String role) =>
    role == 'user' || role == 'assistant' || role == 'tool';

/// `history[targetIndex]` 这条要重新生成时，分支锚点落在哪一条上。
///
/// 返回 -1 表示**前面没有可锚的消息** —— 这条就是对话的第一句。调用方这时
/// 不该建分支：一个锚点在对话开头之前的分支没有共同前缀，切回去等于换一整个
/// 会话，而界面上没有任何地方画得下那个切换器。
int forkPivotIndex(List<ChatMessage> history, int targetIndex) {
  if (targetIndex <= 0 || targetIndex > history.length) return -1;
  for (var i = targetIndex - 1; i >= 0; i--) {
    if (_anchorable(history[i].role)) return i;
  }
  return -1;
}
