/// 前置多模态：不认图的对话模型，也能收到图。
///
/// 思路来自 VPetLLM 的 `PreprocessingMultimodal`：先让一个**视觉模型**把图
/// 描述成文字，再把这段文字交给对话模型。这样一来：
///
///   - 主力模型不必是多模态的。大量本地模型、便宜的文本模型都能用上图片。
///   - **描述是文本，进上下文之后一直是文本**。原生多模态每一轮都要把图
///     重新上传一遍，一张图几百 KB，聊十轮就是十次；而描述只占几百 token，
///     还能被滚动摘要正常压缩。
///   - 描述用的可以是另一个更便宜的模型，通常比让主模型看图便宜得多。
///
/// 代价也要说清楚：描述是**有损**的。「这张截图里第三行的报错是什么」这种
/// 问题，描述模型没提到就永远答不出来了。所以对话模型自己能看图的时候，
/// 默认还是直接发图。
///
/// 几个照抄 VPetLLM 的关键决定：
///   - **多个候选 + 随机挑 + 失败换下一个**。视觉这一步是可选增强，
///     不该因为某个网关抽风就让整条消息发不出去。
///   - **描述这次调用不进主上下文**。它自带一个"请描述这张图"的提示词，
///     那句话不该出现在用户的对话历史里。这里是一次性的临时客户端，
///     天然不带历史。
///   - 全部失败时**把每个候选各自的原因一起报出来**，而不是只报最后一个。
library;

import 'dart:math';

import 'image_parts.dart';
import 'llm_client.dart';

/// 图片怎么送到模型手里。
enum ImageMode {
  /// 看渠道：勾了「对话模型能直接看图」就直发，否则走前置多模态。
  auto,

  /// 一律直发。渠道没勾也发 —— 用户自己知道那个模型行不行，
  /// 出错时的报错来自服务端，比这里拦下来更有信息量。
  native,

  /// 一律走前置多模态。**即使对话模型认图也走**：
  /// 用一个便宜的视觉模型描述一次，比让旗舰模型每轮重读一张图便宜得多。
  preprocess,
}

/// 一个能看图的接入点：某个渠道 + 它配的视觉模型。
class VisionCandidate {
  /// 界面上显示的名字，形如 `渠道名 · 模型名`。
  final String label;

  /// 已经把 model 换成视觉模型的配置（代理、协议、地址都跟着那个渠道）。
  final LlmConfig config;

  /// 取这次请求要带的 Authorization。
  ///
  /// 是个函数而不是一个字符串：OAuth 渠道的 access_token 会过期，
  /// 在列候选的时候取好、等真轮到它时早就失效了 —— 而候选可能永远轮不到。
  final Future<String> Function() auth;

  /// 用户在模型分工表里**点名**的那一个。
  ///
  /// 点名了就先用它，而不是和别的候选一起进随机池 —— 随机是给"地位相同的
  /// 几个"用的，被点名的那个地位不同：用户指定了"图片转文字用 C 渠道的这个
  /// 模型"，结果一半的图被随机丢给了别的渠道，那条指派就等于没设。
  ///
  /// 它失败时**仍然会退到别的候选**。前置多模态是可选增强，不该因为点名的
  /// 那个网关抽风就让整条消息发不出去。
  final bool preferred;

  const VisionCandidate({
    required this.label,
    required this.config,
    required this.auth,
    this.preferred = false,
  });
}

/// 描述的结果。
class VisionResult {
  final bool ok;

  /// 成功时的图片描述。
  final String description;

  /// 成功时用的是哪个候选。
  final String usedLabel;

  /// 失败原因。每个候选各一行。
  final String error;

  const VisionResult._({
    required this.ok,
    this.description = '',
    this.usedLabel = '',
    this.error = '',
  });

  factory VisionResult.success(String description, String label) =>
      VisionResult._(ok: true, description: description, usedLabel: label);

  factory VisionResult.failure(String error) =>
      VisionResult._(ok: false, error: error);
}

/// 默认的描述提示词。
///
/// 明确要求**把文字原样抄出来**：图片十有八九是截图，而截图里最有价值的
/// 就是那几行报错或代码。只说"描述这张图"的话，模型往往回一句
/// 「这是一张显示错误信息的截图」—— 等于什么都没说。
const defaultVisionPrompt = '请详细描述这张图片：主要内容、布局、颜色和风格。'
    '如果图里有文字（代码、报错、界面文案等），请**原样完整地抄写出来**，'
    '不要概括、不要翻译、不要修正其中的拼写。';

/// 把描述和用户原话拼成一条消息。
///
/// 分段打标签而不是直接接在一起：模型必须能分清哪部分是它"看到的"、
/// 哪部分是用户"问的"。混在一段里，模型会把描述里的句子当成用户的要求。
String combineVision(String description, String userText) {
  final hasDescription = description.trim().isNotEmpty;
  final hasText = userText.trim().isNotEmpty;
  if (!hasDescription) return userText;
  if (!hasText) return '[图片内容]\n$description';
  return '[图片内容]\n$description\n\n[用户问题]\n$userText';
}

typedef VisionClientFactory = ImageDescriber Function(
    LlmConfig config, Future<String> Function() auth);

class VisionPreprocessor {
  VisionPreprocessor({
    required this.candidates,
    required this.createClient,
    this.prompt = defaultVisionPrompt,
    Random? random,
  }) : _random = random ?? Random();

  /// 现在有哪些能看图的接入点。每次调用现取 —— 渠道随时可能被改被删。
  final List<VisionCandidate> Function() candidates;

  /// 造一个只用一次的客户端。用完就 cancel。
  final VisionClientFactory createClient;

  final String prompt;
  final Random _random;

  bool get available => candidates().isNotEmpty;

  /// 描述这些图。
  ///
  /// 一次把所有图交给同一个候选，而不是每张图各挑一个：多张图往往是同一件
  /// 事的几个侧面（一份报错的上下两屏），分开描述会丢掉它们之间的关系。
  Future<VisionResult> describe(
    List<String> imagePaths, {
    String? customPrompt,
  }) async {
    if (imagePaths.isEmpty) return VisionResult.failure('没有图片');

    final pool = List<VisionCandidate>.from(candidates());
    if (pool.isEmpty) {
      return VisionResult.failure('没有可用的视觉模型。到「模型分工」里指一个「图片转文字」模型，'
          '或者把当前渠道标记成「对话模型能直接看图」。');
    }

    final failures = <String>[];
    while (pool.isNotEmpty) {
      // 被点名的先用。剩下的随机挑而不是按顺序：按顺序的话第一个永远扛住
      // 全部流量，而它多半也是最贵的那个（用户会把最好的排在前面）。
      final named = pool.indexWhere((c) => c.preferred);
      final candidate =
          pool.removeAt(named >= 0 ? named : _random.nextInt(pool.length));
      final client = createClient(candidate.config, candidate.auth);
      try {
        final description = await client.describeImages(
          imagePaths: imagePaths,
          prompt: customPrompt ?? prompt,
        );
        if (description.trim().isEmpty) {
          // 空描述算失败。当成功的话，后面拼出来的是一条只有标签
          // 没有内容的消息，模型会对着 `[图片内容]` 四个字发挥。
          failures.add('${candidate.label}：返回了空描述');
          continue;
        }
        return VisionResult.success(description.trim(), candidate.label);
      } catch (e) {
        failures.add('${candidate.label}：$e');
      } finally {
        client.cancel();
      }
    }
    return VisionResult.failure('所有视觉模型都失败了：\n${failures.join('\n')}');
  }
}
