/// OAuth 设备码流程、模型端点推导、SKILL.md 解析。
///
/// 这三块的共同点：**全是别人家协议的历史包袱**。靠"改一下连真站点试试"
/// 来验证太慢，而且改坏了不会立刻发现 —— 端点猜错只在某一家上表现出来，
/// frontmatter 少认一种写法只在某个仓库上表现出来。所以全部下沉成纯函数
/// 在这里测。
library;

import 'dart:convert';

import 'package:burrow/src/llm/model_catalog.dart';
import 'package:burrow/src/llm/oauth.dart';
import 'package:burrow/src/skills/skill_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('模型端点推导', () {
    test('裸域名补 /v1/models', () {
      expect(buildModelsUrlCandidates('https://api.deepseek.com'),
          ['https://api.deepseek.com/v1/models']);
    });

    test('已经带 /v1 就只补 /models', () {
      // 再拼一次 /v1 会得到 .../v1/v1/models → 404，
      // 而用户看到的只是"获取失败"，完全无从下手。
      expect(buildModelsUrlCandidates('https://api.siliconflow.cn/v1'),
          ['https://api.siliconflow.cn/v1/models']);
    });

    test('非 v1 的版本段：正确的在前，/v1/models 兜底在后', () {
      expect(
        buildModelsUrlCandidates('https://open.bigmodel.cn/api/paas/v4'),
        [
          'https://open.bigmodel.cn/api/paas/v4/models',
          'https://open.bigmodel.cn/api/paas/v4/v1/models',
        ],
      );
    });

    test('Anthropic 兼容子路径会被剥掉再试根', () {
      final candidates =
          buildModelsUrlCandidates('https://foo.com/api/anthropic');
      expect(candidates.first, 'https://foo.com/api/anthropic/v1/models');
      expect(candidates, contains('https://foo.com/v1/models'));
    });

    test('最长后缀优先：/api/anthropic 不能只被 /anthropic 匹配掉', () {
      final candidates =
          buildModelsUrlCandidates('https://foo.com/api/anthropic');
      // 只剥 /anthropic 的话根会是 https://foo.com/api，那是错的。
      expect(candidates, isNot(contains('https://foo.com/api/v1/models')));
    });

    test('末尾斜杠和空白不影响结果', () {
      expect(buildModelsUrlCandidates('  https://api.deepseek.com//  '),
          ['https://api.deepseek.com/v1/models']);
    });

    test('override 直接短路掉所有推导', () {
      expect(
        buildModelsUrlCandidates('https://whatever',
            override: 'https://x.com/custom'),
        ['https://x.com/custom'],
      );
    });
  });

  group('接口地址拼接', () {
    // 这一组全是那次实测事故的回归：baseUrl 填服务根地址时接口路径少了
    // `/v1`，打到聚合网关的前端页面上，返回 200 + HTML，表现成
    // 「发出去了没有任何回应，也没有报错」。
    test('服务根地址会补上 /v1', () {
      expect(
        resolveApiEndpoint('http://192.168.36.133:3000', '/chat/completions')
            .toString(),
        'http://192.168.36.133:3000/v1/chat/completions',
      );
    });

    test('已经带 /v1 就不再补', () {
      expect(
        resolveApiEndpoint('https://api.openai.com/v1', '/chat/completions')
            .toString(),
        'https://api.openai.com/v1/chat/completions',
      );
    });

    test('非 v1 的版本段沿用它自己的版本', () {
      // 智谱是 /v4。补成 /v4/v1/... 会 404。
      expect(
        resolveApiEndpoint(
                'https://open.bigmodel.cn/api/paas/v4', '/chat/completions')
            .toString(),
        'https://open.bigmodel.cn/api/paas/v4/chat/completions',
      );
    });

    test('用户粘完整接口地址时不重复拼', () {
      expect(
        resolveApiEndpoint(
                'https://x.com/v1/chat/completions', '/chat/completions')
            .toString(),
        'https://x.com/v1/chat/completions',
      );
    });

    test('末尾斜杠不影响', () {
      expect(
        resolveApiEndpoint('http://gw:3000///', '/chat/completions').toString(),
        'http://gw:3000/v1/chat/completions',
      );
    });

    test('Anthropic 的 /messages 走同一套规则', () {
      expect(
        resolveApiEndpoint('https://api.anthropic.com', '/messages').toString(),
        'https://api.anthropic.com/v1/messages',
      );
    });
  });

  group('模型列表解析', () {
    test('OpenAI 标准的 {data:[{id}]}', () {
      final models = parseModelsResponse(
          '{"data":[{"id":"gpt-5","owned_by":"openai"},{"id":"o3"}]}');
      expect(models.map((m) => m.id), ['gpt-5', 'o3']);
      expect(models.first.ownedBy, 'openai');
    });

    test('裸数组和字符串条目也认', () {
      expect(parseModelsResponse('["a","b"]').map((m) => m.id), ['a', 'b']);
    });

    test('去重并排序', () {
      final models = parseModelsResponse('{"models":["b","a","b"]}');
      expect(models.map((m) => m.id), ['a', 'b']);
    });

    test('空列表就是空列表，不抛', () {
      expect(parseModelsResponse('{"data":[],"object":"list"}'), isEmpty);
    });
  });

  group('拉模型', () {
    test('第一个候选 404 时会接着试第二个', () async {
      final tried = <String>[];
      final client = MockClient((request) async {
        tried.add(request.url.toString());
        if (request.url.path.endsWith('/v4/models')) {
          return http.Response('not found', 404);
        }
        return http.Response('{"data":[{"id":"glm-4.6"}]}', 200);
      });

      final models = await fetchModels(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'k',
        client: client,
      );
      expect(models.single.id, 'glm-4.6');
      expect(tried.length, 2);
    });

    test('空列表给的是「去配渠道」而不是「端点不对」', () async {
      // 实测过的场景：new-api 网关认证通过、端点正确，但分组下没有渠道。
      // 报成"获取失败"会让用户去改 baseUrl —— 方向完全错了。
      final client = MockClient(
          (_) async => http.Response('{"data":[],"object":"list"}', 200));
      await expectLater(
        fetchModels(
            baseUrl: 'http://192.168.1.1:3000', apiKey: 'k', client: client),
        throwsA(isA<ModelFetchException>()
            .having((e) => e.message, 'message', contains('没有可用模型'))),
      );
    });
  });

  group('JWT 声明解析', () {
    String jwt(Map<String, Object?> claims) {
      String seg(Map<String, Object?> m) =>
          base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
      return '${seg({'alg': 'none'})}.${seg(claims)}.sig';
    }

    test('能读出顶层声明', () {
      final claims = decodeJwtClaims(jwt({'email': 'a@b.com'}));
      expect(claims?['email'], 'a@b.com');
    });

    test('base64url 缺填充也能解', () {
      // 这是必须支持的：JWT 规范就是去掉填充的，不补回来一个都解不出来。
      final claims = decodeJwtClaims(jwt({'x': 'abc'}));
      expect(claims?['x'], 'abc');
    });

    test('解不出来返回 null 而不是抛', () {
      // 声明读不出来只影响 UI 上显示的邮箱，不该让整个登录失败。
      expect(decodeJwtClaims('not-a-jwt'), isNull);
      expect(decodeJwtClaims('a.!!!.c'), isNull);
    });
  });

  group('凭据过期判定', () {
    test('提前一分钟算过期', () {
      final almost = OAuthCredential(
        accessToken: 't',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      // 卡在边界上刷新会撞时钟漂移，而一次 401 要用户重登，
      // 代价远大于多刷一次。
      expect(almost.isExpired, isTrue);

      final fresh = OAuthCredential(
        accessToken: 't',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
      expect(fresh.isExpired, isFalse);
    });

    test('存取一轮不丢字段', () {
      final original = OAuthCredential(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.parse('2026-01-01T00:00:00.000'),
        email: 'x@y.z',
        accountId: 'acc',
      );
      final restored = OAuthCredential.fromJson(original.toJson());
      expect(restored.accessToken, 'a');
      expect(restored.refreshToken, 'r');
      expect(restored.email, 'x@y.z');
      expect(restored.accountId, 'acc');
      expect(restored.expiresAt, original.expiresAt);
    });
  });

  group('OpenAI 设备码流程', () {
    test('403 是「还没授权」而不是失败', () async {
      // OpenAI 这套不是标准设备码：未授权用 HTTP 状态码表示，
      // 不是 JSON 里的 error 字段。当成失败的话登录永远走不通。
      final client = MockClient((request) async {
        if (request.url.path.endsWith('usercode')) {
          return http.Response(
              '{"device_auth_id":"d1","user_code":"ABCD-1234",'
              '"interval":5,"expires_in":900}',
              200);
        }
        return http.Response('forbidden', 403);
      });
      final flow = OpenAiDeviceFlow(client: client);
      final grant = await flow.start();
      expect(grant.userCode, 'ABCD-1234');
      expect((await flow.poll(grant)).status, PollStatus.pending);
    });

    test('410 是过期', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('usercode')) {
          return http.Response('{"device_auth_id":"d1","user_code":"C"}', 200);
        }
        return http.Response('gone', 410);
      });
      final flow = OpenAiDeviceFlow(client: client);
      final grant = await flow.start();
      expect((await flow.poll(grant)).status, PollStatus.expired);
    });

    test('授权后会再拿 code 去换 token', () async {
      var exchanged = false;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('usercode')) {
          return http.Response('{"device_auth_id":"d1","user_code":"C"}', 200);
        }
        if (path.endsWith('deviceauth/token')) {
          return http.Response(
              '{"authorization_code":"code1","code_verifier":"ver1"}', 200);
        }
        // 这一步就是「不是标准设备码」的地方：拿到的不是 token，
        // 而是一个还要再换一次的 authorization_code。
        exchanged = true;
        expect(request.body, contains('code=code1'));
        expect(request.body, contains('code_verifier=ver1'));
        return http.Response(
            '{"access_token":"at","refresh_token":"rt","expires_in":3600}',
            200);
      });

      final flow = OpenAiDeviceFlow(client: client);
      final result = await flow.poll(await flow.start());
      expect(exchanged, isTrue);
      expect(result.status, PollStatus.authorized);
      expect(result.credential!.accessToken, 'at');
    });

    test('刷新响应不带新 refresh_token 时沿用旧的', () async {
      // 置空会让下一次刷新直接判定"需要重新登录"，用户莫名其妙被登出。
      final client = MockClient((_) async =>
          http.Response('{"access_token":"at2","expires_in":3600}', 200));
      final flow = OpenAiDeviceFlow(client: client);
      final refreshed = await flow.refresh(OAuthCredential(
        accessToken: 'old',
        refreshToken: 'keep-me',
        expiresAt: DateTime.now(),
      ));
      expect(refreshed.accessToken, 'at2');
      expect(refreshed.refreshToken, 'keep-me');
    });
  });

  group('xAI 设备码流程', () {
    MockClient discovering(
        Future<http.Response> Function(http.Request) onToken) {
      return MockClient((request) async {
        if (request.url.path.contains('openid-configuration')) {
          return http.Response(
              '{"device_authorization_endpoint":"https://auth.x.ai/device",'
              '"token_endpoint":"https://auth.x.ai/token"}',
              200);
        }
        if (request.url.path.endsWith('/device')) {
          return http.Response(
              '{"device_code":"dc","user_code":"UC-1",'
              '"verification_uri":"https://x.ai/d",'
              '"verification_uri_complete":"https://x.ai/d?c=UC-1",'
              '"expires_in":600,"interval":5}',
              200);
        }
        return onToken(request);
      });
    }

    test('优先用 verification_uri_complete', () async {
      // 那个地址里已经带了 user_code，用户点开就不用手输。
      final flow = XaiDeviceFlow(
          client: discovering((_) async => http.Response('{}', 200)));
      expect((await flow.start()).verificationUri, 'https://x.ai/d?c=UC-1');
    });

    test('authorization_pending 是正常状态', () async {
      final flow = XaiDeviceFlow(
          client: discovering((_) async =>
              http.Response('{"error":"authorization_pending"}', 400)));
      expect((await flow.poll(await flow.start())).status, PollStatus.pending);
    });

    test('slow_down 会把间隔调大', () async {
      final flow = XaiDeviceFlow(
          client: discovering(
              (_) async => http.Response('{"error":"slow_down"}', 400)));
      final grant = await flow.start();
      final result = await flow.poll(grant);
      expect(result.status, PollStatus.pending);
      expect(result.slowDownTo, greaterThan(grant.interval));
    });

    test('access_denied 和 expired_token 各自映射', () async {
      for (final (error, expected) in [
        ('access_denied', PollStatus.denied),
        ('expired_token', PollStatus.expired),
      ]) {
        final flow = XaiDeviceFlow(
            client: discovering(
                (_) async => http.Response('{"error":"$error"}', 400)));
        expect((await flow.poll(await flow.start())).status, expected);
      }
    });
  });

  group('SKILL.md frontmatter', () {
    test('读出 name 和 description', () {
      final meta = SkillFrontmatter.parse('---\n'
          'name: pdf-tools\n'
          'description: 处理 PDF 时使用\n'
          '---\n\n正文');
      expect(meta.name, 'pdf-tools');
      expect(meta.description, '处理 PDF 时使用');
    });

    test('去掉包裹的引号', () {
      final meta = SkillFrontmatter.parse('---\nname: "x"\n---');
      expect(meta.name, 'x');
    });

    test('缩进的键不算顶层', () {
      // 不跳过的话 `metadata:` 下面的 name 会被当成 skill 名。
      final meta = SkillFrontmatter.parse('---\n'
          'metadata:\n'
          '  name: 不该被取到\n'
          'name: 真名\n'
          '---');
      expect(meta.name, '真名');
    });

    test('折叠块标量 `>` 会把续行拼起来', () {
      // anthropics/skills 里真实的写法。只取冒号后面那一截的话，
      // description 会变成一个字面的 '>'，而那正是决定模型用不用这个
      // skill 的那句话 —— 实测在真仓库上踩到过。
      final meta = SkillFrontmatter.parse('---\n'
          'name: academy-guide\n'
          'description: >\n'
          '  Stop and check this skill before finishing\n'
          '  any reply about Claude products.\n'
          '---\n');
      expect(meta.name, 'academy-guide');
      expect(meta.description,
          'Stop and check this skill before finishing any reply about Claude products.');
    });

    test('保留块标量 `|-` 保留换行', () {
      final meta = SkillFrontmatter.parse('---\n'
          'description: |-\n'
          '  第一行\n'
          '  第二行\n'
          '---\n');
      expect(meta.description, '第一行\n第二行');
    });

    test('块标量结束后仍能读到后面的顶层键', () {
      // 块的续行是缩进的，收完要把非缩进行还给外层循环 ——
      // 吞掉的话 name 就读不到了。
      final meta = SkillFrontmatter.parse('---\n'
          'description: >\n'
          '  一段说明\n'
          'name: 后面的名字\n'
          '---\n');
      expect(meta.description, '一段说明');
      expect(meta.name, '后面的名字');
    });

    test('没有 frontmatter 时全为 null', () {
      expect(SkillFrontmatter.parse('# 只是一篇普通文档').name, isNull);
    });
  });

  group('技能仓库地址解析', () {
    test('owner/name', () {
      final repo = SkillRepo.parse('anthropics/skills')!;
      expect(repo.owner, 'anthropics');
      expect(repo.name, 'skills');
      expect(repo.branch, 'main');
    });

    test('owner/name@branch', () {
      expect(SkillRepo.parse('a/b@dev')!.branch, 'dev');
    });

    test('GitHub 网址', () {
      // 用户手上拿到的多半就是一条链接，让他自己拆成两段是没必要的摩擦。
      final repo = SkillRepo.parse('https://github.com/anthropics/skills')!;
      expect(repo.slug, 'anthropics/skills');
    });

    test('带 /tree/<branch> 的网址能取到分支', () {
      final repo =
          SkillRepo.parse('https://github.com/a/b/tree/next/some/dir')!;
      expect(repo.branch, 'next');
    });

    test('.git 后缀会被去掉', () {
      expect(SkillRepo.parse('https://github.com/a/b.git')!.name, 'b');
    });

    test('看不懂的返回 null', () {
      expect(SkillRepo.parse('随便一句话'), isNull);
      expect(SkillRepo.parse('只有一段'), isNull);
      expect(SkillRepo.parse(''), isNull);
    });
  });
}
