/// 模型能力表：这个模型官方标没标支持视觉 / 工具 / 思考。
///
/// 数据来自 [models.dev](https://models.dev/api.json) —— 一个公开的模型元数据
/// registry。**它只是个提示，不是判决**：用户在渠道里手动勾过的永远优先，
/// 见 [ModelCapability]。registry 的覆盖是有洞的（实测 `gemini-2.0-flash` 和
/// `gemini-3-pro-preview` 都不在里面），手动那条路删不掉。
///
/// ## 为什么要扁平成 id → 能力
///
/// models.dev 是按「服务商 → 模型」两级组织的，而 Burrow 的渠道是一个自由
/// 填写的 baseUrl —— 用户可以指向任何一个聚合网关，我们无从知道它对应
/// models.dev 里的哪个服务商。所以按模型 id 扁平查，和网关是谁无关。
///
/// 代价是同一个 id 在不同服务商下能力标注可能不一致（实测 3546 个 id 里有
/// 322 个存在分歧，基本都是少数二手转售方漏标）。处理办法见 [flattenModelsDev]。
library;

import 'dart:convert';

/// 一个模型的能力标注。
class ModelMeta {
  const ModelMeta({
    this.vision = false,
    this.tools = false,
    this.reasoning = false,
    this.contextWindow = 0,
    this.maxOutput = 0,
  });

  /// 能直接吃图（models.dev 的 `modalities.input` 含 image 或 video）。
  final bool vision;

  /// 支持 function calling（`tool_call`）。
  final bool tools;

  /// 是会思考的模型（`reasoning`）。
  final bool reasoning;

  /// 上下文窗口和最大输出，token。0 = registry 没给。
  final int contextWindow;
  final int maxOutput;

  Map<String, Object?> toJson() => <String, Object?>{
        'v': vision ? 1 : 0,
        't': tools ? 1 : 0,
        'r': reasoning ? 1 : 0,
        if (contextWindow > 0) 'c': contextWindow,
        if (maxOutput > 0) 'o': maxOutput,
      };

  static ModelMeta fromJson(Map<String, Object?> j) => ModelMeta(
        vision: (j['v'] as num? ?? 0) != 0,
        tools: (j['t'] as num? ?? 0) != 0,
        reasoning: (j['r'] as num? ?? 0) != 0,
        contextWindow: (j['c'] as num? ?? 0).toInt(),
        maxOutput: (j['o'] as num? ?? 0).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is ModelMeta &&
      other.vision == vision &&
      other.tools == tools &&
      other.reasoning == reasoning &&
      other.contextWindow == contextWindow &&
      other.maxOutput == maxOutput;

  @override
  int get hashCode =>
      Object.hash(vision, tools, reasoning, contextWindow, maxOutput);
}

/// 把模型 id 归一化到查表用的形式。
///
/// 同一个模型在不同网关下写法不一样：OpenRouter 是 `anthropic/claude-x`，
/// Gemini 的列表接口给 `models/gemini-2.5-flash`，硅基流动那边大小写还不
/// 统一。不归一化的话，这几种写法一个都查不到。
///
/// **只砍最后一段之前的厂商前缀，不递归砍**：`deepseek-ai/DeepSeek-V3` 要
/// 变成 `deepseek-v3`，而 `gpt-4o` 本来就没有斜杠，不能动。
String normalizeModelId(String raw) {
  var id = raw.trim().toLowerCase();
  if (id.isEmpty) return id;
  // Gemini 的列表接口返回 `models/xxx`，和厂商前缀是一回事，一起砍掉。
  final slash = id.lastIndexOf('/');
  if (slash >= 0 && slash < id.length - 1) id = id.substring(slash + 1);
  // 有的网关会在后面挂 `:free`、`:nitro` 这种变体后缀，能力和本体一样。
  final colon = id.indexOf(':');
  if (colon > 0) id = id.substring(0, colon);
  return id;
}

/// 把 models.dev 的两级响应压成 `归一化 id → 能力`。
///
/// **同一个 id 在多个服务商下标注不一致时按多数决。** 实测分歧几乎全是
/// 「三四家标了支持、一两家二手转售方漏标」这种形状，取多数能还原真实能力；
/// 打平票时取 false —— 少报一个能力只是走降级路径（图片先转文字描述），
/// 多报一个能力是直接 400 把这条消息打挂，两者代价不对等。
Map<String, ModelMeta> flattenModelsDev(Object? decoded) {
  if (decoded is! Map) return const <String, ModelMeta>{};

  // id → 每一票的 (vision, tools, reasoning)，以及见过的最大窗口。
  final votes = <String, List<List<bool>>>{};
  final limits = <String, List<int>>{};

  for (final provider in decoded.values) {
    if (provider is! Map) continue;
    final models = provider['models'];
    if (models is! Map) continue;
    for (final entry in models.entries) {
      final raw = (entry.value is Map ? entry.value as Map : const {});
      final id = normalizeModelId(
        (raw['id'] ?? entry.key).toString(),
      );
      if (id.isEmpty) continue;

      final modalities = raw['modalities'];
      final input = modalities is Map ? modalities['input'] : null;
      final vision =
          input is List && input.any((m) => m == 'image' || m == 'video');

      votes.putIfAbsent(id, () => <List<bool>>[]).add(<bool>[
        vision,
        raw['tool_call'] == true,
        raw['reasoning'] == true,
      ]);

      final limit = raw['limit'];
      if (limit is Map) {
        final slot = limits.putIfAbsent(id, () => <int>[0, 0]);
        final context = (limit['context'] as num?)?.toInt() ?? 0;
        final output = (limit['output'] as num?)?.toInt() ?? 0;
        // 窗口取见过的最大值：转售方常常把窗口调小，但那是它自己的限制，
        // 不是模型的能力。
        if (context > slot[0]) slot[0] = context;
        if (output > slot[1]) slot[1] = output;
      }
    }
  }

  final out = <String, ModelMeta>{};
  for (final entry in votes.entries) {
    final ballots = entry.value;
    bool majority(int field) {
      var yes = 0;
      for (final ballot in ballots) {
        if (ballot[field]) yes++;
      }
      return yes * 2 > ballots.length;
    }

    final limit = limits[entry.key] ?? const <int>[0, 0];
    out[entry.key] = ModelMeta(
      vision: majority(0),
      tools: majority(1),
      reasoning: majority(2),
      contextWindow: limit[0],
      maxOutput: limit[1],
    );
  }
  return out;
}

/// 快照 / 缓存的序列化形式。
String encodeRegistry(Map<String, ModelMeta> models) => jsonEncode(
      <String, Object?>{
        for (final entry in models.entries) entry.key: entry.value.toJson(),
      },
    );

/// 读快照 / 读缓存文件。**坏了就当空的，不抛。**
///
/// 缓存文件是可能损坏的（写到一半断电、存储满了），而它坏掉的后果应该是
/// 「这次没有能力提示」，不该是启动时崩一次。
Map<String, ModelMeta> decodeRegistry(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const <String, ModelMeta>{};
  }
  if (decoded is! Map) return const <String, ModelMeta>{};
  final out = <String, ModelMeta>{};
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (value is Map<String, Object?>) {
      out[entry.key.toString()] = ModelMeta.fromJson(value);
    }
  }
  return out;
}

/// 查表用的入口。查不到就是查不到，返回 null —— 调用方据此退回渠道默认值。
class ModelRegistry {
  ModelRegistry(this._models);

  ModelRegistry.empty() : _models = const <String, ModelMeta>{};

  final Map<String, ModelMeta> _models;

  int get size => _models.length;

  ModelMeta? lookup(String modelId) => _models[normalizeModelId(modelId)];
}
