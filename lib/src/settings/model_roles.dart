/// 模型分工：一件事用**哪个渠道的哪个模型**。
///
/// ## 为什么需要这张表
///
/// 在这之前，除了「哪个渠道自己配了视觉模型」以外的所有事都绑死在**当前
/// 渠道**上：嵌入模型只有模型名，地址和密钥现取当前渠道的；摘要模型是
/// 渠道自己的一个字段。于是「聊天用 A、嵌入用 B、图片转文字用 C」这个再
/// 正常不过的组合根本配不出来 —— 想用 B 的嵌入模型，就得把整个对话也搬到
/// B 上去。
///
/// 更糟的是它**不报错**：在 B 的模型列表里挑一个嵌入模型，程序照样拿这个
/// 名字去 A 的地址上请求。运气好是 404，运气不好 A 那边刚好有个同名模型，
/// 于是照常计费、照常返回一堆和 B 完全不同空间的向量。
///
/// 所以指派必须是**一对**（渠道 + 模型），不能只是一个模型名。这张表就是
/// 那些对。
library;

import 'package:flutter/foundation.dart';

/// 一件需要模型的活儿。
///
/// 只列**真的会各用各的**那几件。生成参数（temperature、思考强度）不在
/// 这里 —— 那些是"我希望模型怎么答"，跟人走不跟接入点走。
enum ModelRole {
  /// 每一轮对话。它就是「当前渠道 + 当前模型」，没有独立存储：
  /// 两份状态迟早会不一致，而不一致的表现是"顶栏显示的和实际发出去的不同"。
  chat,

  /// 记忆检索的第三路（向量余弦）。可选。
  embedding,

  /// 前置多模态里那个把图描述成文字的模型。
  vision,

  /// 上下文超了之后压缩历史用的。
  summary;

  String get label => switch (this) {
        ModelRole.chat => '对话模型',
        ModelRole.embedding => '嵌入模型',
        ModelRole.vision => '图片转文字',
        ModelRole.summary => '摘要模型',
      };

  String get hint => switch (this) {
        ModelRole.chat => '每一轮回复都用它。改这一项会把当前渠道一起切过去',
        ModelRole.embedding => '记忆检索的语义那一路。不配就只用 BM25 + 覆盖率两路词法',
        ModelRole.vision => '对话模型不认图时，先让它把图描述成文字',
        ModelRole.summary => '上下文超了之后压缩历史。不配就用对话渠道自己配的那个',
      };

  /// 没指派时会发生什么。表里那一行的灰字。
  String get unsetLabel => switch (this) {
        ModelRole.chat => '还没配',
        ModelRole.embedding => '不启用',
        ModelRole.vision => '跟随渠道设置',
        ModelRole.summary => '跟随对话渠道',
      };

  /// 这一项可以不配。对话模型不行 —— 没有它整个 app 都不能用。
  bool get optional => this != ModelRole.chat;

  String get storage => name;

  static ModelRole? fromStorage(String? raw) {
    for (final role in ModelRole.values) {
      if (role.name == raw) return role;
    }
    return null;
  }
}

/// 一条指派：**哪个渠道**的**哪个模型**。
///
/// 渠道存 id 而不是名字或地址：名字随时会被改，地址随时会被改，
/// 而"用户当初指的是哪个渠道"这件事不该跟着变。
@immutable
class ModelRef {
  const ModelRef({required this.channelId, required this.model});

  final String channelId;
  final String model;

  Map<String, Object?> toJson() => <String, Object?>{
        'channel': channelId,
        'model': model,
      };

  static ModelRef? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final channelId = raw['channel'];
    final model = raw['model'];
    if (channelId is! String || model is! String) return null;
    if (channelId.isEmpty || model.trim().isEmpty) return null;
    return ModelRef(channelId: channelId, model: model.trim());
  }

  @override
  bool operator ==(Object other) =>
      other is ModelRef && other.channelId == channelId && other.model == model;

  @override
  int get hashCode => Object.hash(channelId, model);
}

/// 这个角色指到这种协议的渠道上会不会出事。没问题返回 null。
///
/// 嵌入和摘要走的是**写死的 OpenAI 兼容端点**（`/embeddings`、
/// `/chat/completions`），不跟着渠道的 `apiFormat` 变。指到一个 Anthropic
/// 或 Gemini 原生渠道上，表现分别是「向量路一直不可用」和「摘要永远是空的」
/// —— 两者都**不会抛**，只会安静地少一块功能。这句话就是拿来提前说的。
String? roleProtocolWarning(ModelRole role, String apiFormat) {
  const names = <String, String>{
    'anthropic': 'Anthropic',
    'geminiNative': 'Gemini 原生',
    'chatgptOAuth': 'ChatGPT OAuth',
  };
  final name = names[apiFormat];
  if (name == null) return null;
  return switch (role) {
    // 摘要那条路认得 ChatGPT OAuth，别的原生协议不认。
    ModelRole.summary when apiFormat == 'chatgptOAuth' => null,
    ModelRole.embedding => '这个渠道是 $name 协议，而嵌入走的是 OpenAI 兼容的 '
        '/embeddings —— 多半会一直不可用',
    ModelRole.summary => '这个渠道是 $name 协议，而摘要走的是 OpenAI 兼容的 '
        '/chat/completions —— 多半会一直摘不出东西',
    // 对话和视觉都走各协议自己的那条路径，没有这个问题。
    ModelRole.chat || ModelRole.vision => null,
  };
}
