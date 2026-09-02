import 'package:burrow/src/llm/google_oauth.dart';
import 'package:burrow/src/llm/oauth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('家族分组', () {
    test('Google 两种模式归一家，另外两家各自成家', () {
      final providers = <OAuthProvider>[
        OpenAiDeviceFlow(),
        XaiDeviceFlow(),
        GoogleCodeAssistFlow(),
        GoogleVertexFlow(),
      ];
      final byFamily = <String, List<OAuthProvider>>{};
      for (final p in providers) {
        byFamily.putIfAbsent(p.family, () => <OAuthProvider>[]).add(p);
      }
      expect(byFamily, hasLength(3));
      expect(byFamily[googleFamily], hasLength(2));
      expect(byFamily[googleFamily]!.first.familyName, 'Google 账号');
      // 同一家的两个模式必须有各自的名字，否则子页里两行长得一模一样。
      expect(
        byFamily[googleFamily]!.map((p) => p.modeName).toSet(),
        hasLength(2),
      );
    });

    test('单模式家族三个名字一致', () {
      final openai = OpenAiDeviceFlow();
      expect(openai.family, openai.id);
      expect(openai.familyName, openai.displayName);
      expect(openai.modeName, openai.displayName);
    });
  });

  group('套餐余量', () {
    test('summary 只在拿到百分比时才写"剩多少"', () {
      const onlyPlan = AccountQuota(plan: 'ChatGPT Plus');
      expect(onlyPlan.summary, 'ChatGPT Plus');

      const withUsage = AccountQuota(plan: 'ChatGPT Plus', usedPercent: 0.25);
      expect(withUsage.summary, 'ChatGPT Plus · 剩 75%');
    });

    test('JSON 往返；没有 plan 的当无效', () {
      final quota = AccountQuota(
        plan: 'Pro',
        detail: 'x',
        usedPercent: 0.5,
        resetsAt: DateTime(2026, 9, 1, 12),
        fetchedAt: DateTime(2026, 9, 1, 11),
      );
      final back = AccountQuota.fromJson(quota.toJson())!;
      expect(back.plan, 'Pro');
      expect(back.usedPercent, 0.5);
      expect(back.resetsAt, DateTime(2026, 9, 1, 12));
      expect(AccountQuota.fromJson(const <String, Object?>{}), isNull);
    });

    test('Vertex 说清是按量计费，不是"额度未知"', () async {
      final quota = await GoogleVertexFlow().fetchQuota(
        OAuthCredential(accessToken: 'a', expiresAt: DateTime.now()),
      );
      expect(quota!.plan, '按量计费');
      expect(quota.usedPercent, isNull);
      expect(quota.detail, contains('没有配额余量'));
    });

    test('xAI 返回结果而不是 null —— "对面没接口"和"这家不支持"不是一回事', () async {
      final quota = await XaiDeviceFlow().fetchQuota(
        OAuthCredential(accessToken: 'a', expiresAt: DateTime.now()),
      );
      expect(quota, isNotNull);
      expect(quota!.usedPercent, isNull);
      expect(quota.detail, contains('没有公开的额度查询接口'));
    });
  });

  group('Codex 响应头里的余量', () {
    test('读得出百分比和重置时间', () {
      final quota = parseCodexRateLimit(
        <String, String>{
          'x-codex-primary-used-percent': '42.5',
          'x-codex-primary-reset-after-seconds': '3600',
        },
        plan: 'ChatGPT Plus',
      );
      expect(quota!.usedPercent, closeTo(0.425, 0.001));
      expect(quota.plan, 'ChatGPT Plus');
      expect(quota.resetsAt!.isAfter(DateTime.now()), isTrue);
      expect(quota.summary, 'ChatGPT Plus · 剩 57%');
    });

    test('头名字不认识就返回 null，不编一个数', () {
      // 这些头名不在任何公开文档里，是照 Codex CLI 的行为写的。将来改了，
      // 后果必须是"余量不显示"，而不是"显示一个错的余量"。
      expect(
        parseCodexRateLimit(
          <String, String>{'x-something-else': '10'},
          plan: 'ChatGPT',
        ),
        isNull,
      );
      expect(parseCodexRateLimit(const <String, String>{}, plan: 'x'), isNull);
    });

    test('百分比越界被钳住', () {
      final quota = parseCodexRateLimit(
        <String, String>{'x-codex-primary-used-percent': '250'},
        plan: 'x',
      );
      expect(quota!.usedPercent, 1.0);
    });
  });

  group('Code Assist 档位解析', () {
    test('真实返回：free-tier 被判 UNSUPPORTED_CLIENT', () {
      // 这份 JSON 是 2026-09 从一个 Google AI Pro 账号上实测抓下来的。
      // 注意它**没有 currentTier** —— 原来的实现在这种情况下回落成写死的
      // 「Gemini 免费额度」，那是编的，而真相恰恰相反：不能用。
      final quota = parseCodeAssistTier(<String, Object?>{
        'allowedTiers': <Object?>[
          <String, Object?>{
            'id': 'standard-tier',
            'name': 'Gemini Code Assist',
            'userDefinedCloudaicompanionProject': true,
          },
        ],
        'ineligibleTiers': <Object?>[
          <String, Object?>{
            'tierId': 'free-tier',
            'tierName': 'Gemini Code Assist for individuals',
            'reasonCode': 'UNSUPPORTED_CLIENT',
            'reasonMessage': 'This client is no longer supported…',
          },
        ],
      });
      // allowedTiers 非空时先报它 —— 那是这个账号**能用**的东西。
      expect(quota.plan, 'Gemini Code Assist');
      expect(quota.detail, contains('GCP 项目'));
      expect(quota.plan, isNot(contains('免费')));
    });

    test('只有 ineligibleTiers 时，把 Google 的原话带出来', () {
      final quota = parseCodeAssistTier(<String, Object?>{
        'ineligibleTiers': <Object?>[
          <String, Object?>{
            'tierId': 'free-tier',
            'tierName': '个人免费额度',
            'reasonMessage': '迁到 Antigravity',
          },
        ],
      });
      expect(quota.plan, '不可用');
      expect(quota.detail, contains('迁到 Antigravity'));
    });

    test('有 currentTier 时优先用它', () {
      final quota = parseCodeAssistTier(<String, Object?>{
        'currentTier': <String, Object?>{'id': 'free-tier', 'name': '个人版'},
        'allowedTiers': <Object?>[
          <String, Object?>{'id': 'standard-tier', 'name': '标准版'},
        ],
      });
      expect(quota.plan, '个人版');
    });

    test('什么都没有时说"未知"，不编一个档位', () {
      final quota = parseCodeAssistTier(const <String, Object?>{});
      expect(quota.plan, '档位未知');
      expect(quota.usedPercent, isNull);
    });
  });
}
