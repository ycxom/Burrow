import 'dart:async';
import 'dart:convert';

import 'package:burrow/src/agent/agent_loop.dart' show TokenUsage;
import 'package:burrow/src/agent/tools.dart';
import 'package:burrow/src/context/overflow_manager.dart';
import 'package:burrow/src/llm/gemini_protocol.dart';
import 'package:burrow/src/llm/google_oauth.dart';
import 'package:burrow/src/llm/model_catalog.dart';
import 'package:burrow/src/llm/image_parts.dart';
import 'package:burrow/src/llm/oauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ChatMessage _msg(String role, String content,
        {List<String> images = const []}) =>
    ChatMessage(
      role: role,
      content: content,
      at: DateTime(2026, 1, 1),
      images: images,
    );

void main() {
  group('客户端凭据', () {
    test('内嵌凭据能被认出来', () {
      expect(GoogleOAuthClient.bundled.isBundled, isTrue);
      expect(
        const GoogleOAuthClient(id: 'mine', secret: 's').isBundled,
        isFalse,
      );
    });

    test('JSON 往返；缺 id 的当没设过', () {
      const client = GoogleOAuthClient(id: 'abc', secret: 'xyz');
      final back = GoogleOAuthClient.fromJson(client.toJson());
      expect(back!.id, 'abc');
      expect(back.secret, 'xyz');
      expect(
          GoogleOAuthClient.fromJson(<String, Object?>{'secret': 'x'}), isNull);
    });
  });

  group('Vertex 地址拼装', () {
    test('区域端点', () {
      expect(
        GoogleVertexFlow.vertexBaseUrl(
            project: 'my-proj', location: 'us-central1'),
        'https://us-central1-aiplatform.googleapis.com'
        '/v1/projects/my-proj/locations/us-central1/endpoints/openapi',
      );
    });

    test('global 是特例：主机名不带区域前缀', () {
      // 照通用规则拼会得到 global-aiplatform.googleapis.com，那个域名不存在。
      final url =
          GoogleVertexFlow.vertexBaseUrl(project: 'p', location: 'global');
      expect(url, startsWith('https://aiplatform.googleapis.com/'));
      expect(url, contains('/locations/global/'));
    });

    test('区域留空按 global 处理', () {
      expect(
        GoogleVertexFlow.vertexBaseUrl(project: 'p', location: '  '),
        GoogleVertexFlow.vertexBaseUrl(project: 'p', location: 'global'),
      );
    });
  });

  group('provider 元信息', () {
    test('两个后端的协议和地址不同 —— 这正是分成两个 provider 的理由', () {
      final free = GoogleCodeAssistFlow();
      final vertex = GoogleVertexFlow();
      expect(free.apiFormat, 'gemini');
      expect(free.apiBaseUrl, contains('cloudcode-pa.googleapis.com'));
      // Vertex 复用现成的 openAI 协议路径，一行新协议代码都不用写。
      expect(vertex.apiFormat, 'openAI');
      expect(vertex.apiBaseUrl, isEmpty);
      expect(free.id, isNot(vertex.id));
    });

    test('两家都是回跳流程，不是设备码', () {
      expect(GoogleCodeAssistFlow(), isA<RedirectFlowProvider>());
      expect(GoogleVertexFlow(), isA<RedirectFlowProvider>());
      expect(GoogleCodeAssistFlow(), isNot(isA<DeviceFlowProvider>()));
    });
  });

  group('回跳登录', () {
    // 51121 落在 Windows 的 Hyper-V 保留端口段里（51113–51212），在 Windows
    // 上 bind 直接 WSAEACCES —— 整组测试一个都跑不了。这里换成 0 让内核挑
    // 一个：这一组测的是"授权地址拼得对不对、state 校不校、回跳解析对不对"，
    // 和具体哪个端口无关。**端口本身固定在 51121 由下面单独一条钉住。**
    setUp(() => googleRedirectPort = 0);
    tearDown(resetGoogleRedirectPort);

    const grantedGoogleScopes = 'email profile openid '
        'https://www.googleapis.com/auth/aicode '
        'https://www.googleapis.com/auth/cloud-platform '
        'https://www.googleapis.com/auth/userinfo.email '
        'https://www.googleapis.com/auth/userinfo.profile '
        'https://www.googleapis.com/auth/cclog '
        'https://www.googleapis.com/auth/experimentsandconfigs';

    http.Client validatedGoogleClient({
      String clientId = 'test-client',
      String scopes = grantedGoogleScopes,
      String email = 'user@example.com',
      bool emailVerified = true,
      String accessToken = 'at-1',
      String? refreshToken = 'rt-1',
      void Function(http.Request request)? onTokenRequest,
    }) =>
        MockClient((request) async {
          if (request.url.host == 'oauth2.googleapis.com' &&
              request.url.path == '/token') {
            onTokenRequest?.call(request);
            return http.Response(
              jsonEncode(<String, Object?>{
                'access_token': accessToken,
                if (refreshToken != null) 'refresh_token': refreshToken,
                'expires_in': 3600,
              }),
              200,
            );
          }
          if (request.url.host == 'www.googleapis.com' &&
              request.url.path == '/oauth2/v3/tokeninfo') {
            expect(request.url.queryParameters['access_token'], accessToken);
            return http.Response(
              jsonEncode(<String, Object?>{
                'azp': clientId,
                'scope': scopes,
                'expires_in': 3500,
              }),
              200,
            );
          }
          if (request.url.host == 'www.googleapis.com' &&
              request.url.path == '/oauth2/v2/userinfo') {
            expect(request.headers['authorization'], 'Bearer $accessToken');
            return http.Response(
              jsonEncode(<String, Object?>{
                'email': email,
                'verified_email': emailVerified,
              }),
              200,
            );
          }
          return http.Response('unexpected request: ${request.url}', 500);
        });

    /// 走完整条路：起会话 → 解析授权地址 → 真的往回环端口发一次回跳 →
    /// tokeninfo / userinfo 也走 MockClient，回环 HTTP 则是真的。
    Future<(RedirectAuthSession, Uri)> startSession({
      http.Client? tokenClient,
    }) async {
      final flow = GoogleCodeAssistFlow(
        client:
            const GoogleOAuthClient(id: 'test-client', secret: 'test-secret'),
        httpClient: tokenClient ?? validatedGoogleClient(),
      );
      final session = await flow.start();
      return (session, Uri.parse(session.authorizationUrl));
    }

    test('授权地址带齐 PKCE、state 和回环回跳', () async {
      final (session, uri) = await startSession();
      addTearDown(session.cancel);

      final q = uri.queryParameters;
      expect(uri.host, 'accounts.google.com');
      expect(q['client_id'], 'test-client');
      expect(q['response_type'], 'code');
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], isNotEmpty);
      // challenge 是 verifier 的哈希，不能等于 verifier 本身。
      expect(q['code_challenge'], isNot(contains('=')));
      expect(q['state'], isNotEmpty);
      // 没有 offline 就拿不到 refresh_token，一小时后用户要重登。
      expect(q['access_type'], 'offline');
      // 不强制同意屏的话，重复登录不会再下发 refresh_token。
      expect(q['prompt'], 'consent');
      expect(q['scope'], contains('cloud-platform'));
      expect(q['scope'], contains('auth/aicode'));
      expect(q['scope'], contains('auth/cclog'));
      expect(q['scope'], contains('auth/experimentsandconfigs'));

      final redirect = Uri.parse(q['redirect_uri']!);
      expect(redirect.host, 'localhost');
      expect(redirect.path, '/oauth-callback');
    });

    test('生产环境的回跳端口固定是 51121', () {
      // 这个值不能动：它是登记在 Antigravity OAuth 客户端名下的回跳地址，
      // 换一个 Google 直接 redirect_uri_mismatch。上面那组为了能在 Windows
      // 上跑把它改成了 0，所以真正的默认值必须在这里单独钉一次。
      resetGoogleRedirectPort();
      expect(googleRedirectPort, 51121);
    });

    test('每次登录的 verifier 和 state 都不一样', () async {
      final (a, uriA) = await startSession();
      await a.cancel();
      final (b, uriB) = await startSession();
      addTearDown(b.cancel);
      expect(
        uriA.queryParameters['code_challenge'],
        isNot(uriB.queryParameters['code_challenge']),
      );
      expect(
        uriA.queryParameters['state'],
        isNot(uriB.queryParameters['state']),
      );
    });

    test('带对 state 的回跳换出凭据', () async {
      late http.Request captured;
      final (session, uri) = await startSession(
        tokenClient: validatedGoogleClient(
          onTokenRequest: (request) => captured = request,
        ),
      );

      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      final state = uri.queryParameters['state']!;
      final page = await http.get(
        redirect
            .replace(queryParameters: {'code': 'auth-code', 'state': state}),
      );
      // 浏览器要看到一句人话，否则用户不知道该不该切回 app。
      expect(page.statusCode, 200);
      expect(page.body, contains('登录成功'));

      final credential = await session.result;
      expect(credential.accessToken, 'at-1');
      expect(credential.refreshToken, 'rt-1');
      expect(credential.email, 'user@example.com');
      expect(credential.isExpired, isFalse);

      // 换 token 时必须带 verifier 和 secret —— Google 的桌面客户端
      // 即使用了 PKCE 也仍然校验 secret。
      final body = Uri.splitQueryString(captured.body);
      expect(body['grant_type'], 'authorization_code');
      expect(body['code'], 'auth-code');
      expect(body['code_verifier'], isNotEmpty);
      expect(body['client_secret'], 'test-secret');
      expect(body['redirect_uri'], redirect.toString());
    });

    test('state 对不上的回跳被忽略，会话继续等', () async {
      final (session, uri) = await startSession();
      addTearDown(session.cancel);
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);

      final page = await http.get(
        redirect.replace(
          queryParameters: {'code': 'stolen', 'state': 'wrong-state'},
        ),
      );
      expect(page.body, contains('不属于本次登录'));

      // 会话没有结束 —— 真正的回跳可能还在路上。
      var done = false;
      unawaited(session.result.then(
        (_) => done = true,
        onError: (_) => done = true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(done, isFalse);
    });

    test('带 error 但 state 不对的回跳也不能取消登录', () async {
      final (session, uri) = await startSession();
      addTearDown(session.cancel);
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);

      final page = await http.get(
        redirect.replace(
          queryParameters: <String, String>{
            'error': 'access_denied',
            'error_description': '<script>not trusted</script>',
            'state': 'wrong-state',
          },
        ),
      );
      expect(page.statusCode, 400);
      expect(page.body, contains('不属于本次登录'));
      expect(page.body, isNot(contains('<script>')));

      var done = false;
      unawaited(session.result.then(
        (_) => done = true,
        onError: (_) => done = true,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(done, isFalse);
    });

    test('授权被拒时以 OAuthException 结束，错误描述会被转义', () async {
      final (session, uri) = await startSession();
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      final page = await http.get(
        redirect.replace(queryParameters: <String, String>{
          'error': 'access_denied',
          'error_description': '<script>not trusted</script>',
          'state': uri.queryParameters['state']!,
        }),
      );
      expect(page.statusCode, 400);
      // 断言的是**性质**，不是某一串确切的实体编码：`HtmlEscape` 默认那一档
      // 连 `/` 都转（`&#47;`），所以 `&lt;/script&gt;` 这种写法永远对不上。
      // 真正要保证的是"注入进不去、原文还看得见"。
      expect(page.body, isNot(contains('<script>')));
      expect(page.body, contains('&lt;script&gt;'));
      expect(page.body, contains('not trusted'));
      await expectLater(session.result, throwsA(isA<OAuthException>()));
    });

    test('token 属于别的 OAuth 客户端时不算登录成功', () async {
      final (session, uri) = await startSession(
        tokenClient: validatedGoogleClient(clientId: 'another-client'),
      );
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      final page = await http.get(redirect.replace(queryParameters: {
        'code': 'auth-code',
        'state': uri.queryParameters['state']!,
      }));

      expect(page.statusCode, 401);
      expect(page.body, contains('登录验证失败'));
      await expectLater(session.result, throwsA(isA<OAuthException>()));
    });

    test('token 缺少 cloud-platform scope 时不算登录成功', () async {
      final (session, uri) = await startSession(
        tokenClient: validatedGoogleClient(
          scopes: grantedGoogleScopes.replaceAll(
            'https://www.googleapis.com/auth/cloud-platform ',
            '',
          ),
        ),
      );
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      final page = await http.get(redirect.replace(queryParameters: {
        'code': 'auth-code',
        'state': uri.queryParameters['state']!,
      }));

      expect(page.statusCode, 401);
      expect(page.body, contains('缺少必要 scope'));
      await expectLater(session.result, throwsA(isA<OAuthException>()));
    });

    test('userinfo 返回未验证邮箱时不算登录成功', () async {
      final (session, uri) = await startSession(
        tokenClient: validatedGoogleClient(emailVerified: false),
      );
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      final page = await http.get(redirect.replace(queryParameters: {
        'code': 'auth-code',
        'state': uri.queryParameters['state']!,
      }));

      expect(page.statusCode, 401);
      await expectLater(session.result, throwsA(isA<OAuthException>()));
    });

    test('取消会收掉监听端口', () async {
      final (session, uri) = await startSession();
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      await session.cancel();
      await expectLater(session.result, throwsA(isA<OAuthException>()));
      // 端口已经关了，再连就该失败 —— 留着一个谁都能连的本机端口是攻击面。
      await expectLater(
        http.get(redirect).timeout(const Duration(seconds: 2)),
        throwsA(anything),
      );
    });

    test('刷新时带上旧 refresh_token —— 响应里不会再给一个', () async {
      late http.Request captured;
      final flow = GoogleVertexFlow(
        client: const GoogleOAuthClient(id: 'cid', secret: 'sec'),
        httpClient: validatedGoogleClient(
          clientId: 'cid',
          accessToken: 'at-2',
          refreshToken: null,
          onTokenRequest: (request) => captured = request,
        ),
      );
      final refreshed = await flow.refresh(OAuthCredential(
        accessToken: 'old',
        refreshToken: 'rt-keep',
        expiresAt: DateTime.now(),
      ));
      expect(refreshed.accessToken, 'at-2');
      // 不接住旧的就等于"登录一小时后必掉线"。
      expect(refreshed.refreshToken, 'rt-keep');
      expect(
          Uri.splitQueryString(captured.body)['grant_type'], 'refresh_token');
    });

    test('没有 refresh_token 时直接说要重登', () async {
      final flow = GoogleVertexFlow();
      await expectLater(
        flow.refresh(OAuthCredential(
          accessToken: 'a',
          expiresAt: DateTime.now(),
        )),
        throwsA(isA<OAuthException>()),
      );
    });
  });

  group('Gemini 线格式', () {
    test('角色映射：system 提到顶层，assistant 变 model，tool 变 user', () {
      final contents = geminiContents(
        <ChatMessage>[
          _msg('system', '你是助手'),
          _msg('user', '你好'),
          _msg('assistant', '你好'),
          _msg('tool', 'ls 的输出'),
        ],
        const <String, InlineImage>{},
      );
      expect(contents.map((c) => c['role']), <String>['user', 'model', 'user']);
      final system =
          geminiSystemInstruction(<ChatMessage>[_msg('system', '你是助手')]);
      expect(system, isNotNull);
    });

    test('相邻同角色合并 —— Gemini 要求严格交替', () {
      final contents = geminiContents(
        <ChatMessage>[
          _msg('user', '检索片段'),
          _msg('user', '真正的问题'),
        ],
        const <String, InlineImage>{},
      );
      expect(contents, hasLength(1));
      expect((contents.single['parts'] as List), hasLength(2));
    });

    test('空消息不会被丢掉，也不会发出空 parts', () {
      final contents = geminiContents(
        <ChatMessage>[_msg('user', '')],
        const <String, InlineImage>{},
      );
      expect(contents, hasLength(1));
      expect((contents.single['parts'] as List), isNotEmpty);
    });

    test('图片进 inlineData', () {
      final contents = geminiContents(
        <ChatMessage>[
          _msg('user', '看这个', images: <String>['/a.jpg'])
        ],
        <String, InlineImage>{
          '/a.jpg': const InlineImage(
            path: '/a.jpg',
            mediaType: 'image/jpeg',
            base64Data: 'AAAA',
            bytes: 3,
          ),
        },
      );
      final parts = contents.single['parts'] as List;
      final inline = parts.whereType<Map>().firstWhere(
            (p) => p.containsKey('inlineData'),
          );
      expect((inline['inlineData'] as Map)['mimeType'], 'image/jpeg');
    });

    test('schema 清洗：丢未知键、type 转大写', () {
      final cleaned = sanitizeGeminiSchema(<String, Object?>{
        r'$schema': 'http://json-schema.org/draft-07/schema#',
        'additionalProperties': false,
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{'type': 'string', 'description': '路径'},
        },
        'required': <String>['path'],
      }) as Map<String, Object?>;

      // 多余的键不是被忽略，是会让整轮 400 —— 所以必须真的删掉。
      expect(cleaned.containsKey(r'$schema'), isFalse);
      expect(cleaned.containsKey('additionalProperties'), isFalse);
      expect(cleaned['type'], 'OBJECT');
      final props = cleaned['properties'] as Map<String, Object?>;
      expect((props['path'] as Map)['type'], 'STRING');
      expect((props['path'] as Map)['description'], '路径');
    });

    test('工具声明外层结构', () {
      final tools = geminiTools(<ToolSpec>[
        const ToolSpec('exec', '执行命令', <String, Object?>{'type': 'object'}),
      ]);
      expect(tools.single.containsKey('functionDeclarations'), isTrue);
      final decl = (tools.single['functionDeclarations'] as List).single as Map;
      expect(decl['name'], 'exec');
      expect((decl['parameters'] as Map)['type'], 'OBJECT');
    });

    test('响应解析：文本、工具调用、用量', () {
      final chunk = parseGeminiResponse(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'role': 'model',
              'parts': <Object?>[
                <String, Object?>{'text': '好的'},
                <String, Object?>{
                  'functionCall': <String, Object?>{
                    'name': 'exec',
                    'args': <String, Object?>{'cmd': 'ls'},
                  },
                },
              ],
            },
          },
        ],
        'usageMetadata': <String, Object?>{
          'promptTokenCount': 120,
          'candidatesTokenCount': 8,
          'cachedContentTokenCount': 64,
        },
      });
      expect(chunk.text, '好的');
      expect(chunk.calls.single.name, 'exec');
      expect(chunk.calls.single.args['cmd'], 'ls');
      expect(chunk.usage, isA<TokenUsage>());
      expect(chunk.usage!.input, 120);
      expect(chunk.usage!.cached, 64);
    });

    test('空响应不崩', () {
      final chunk = parseGeminiResponse(const <String, Object?>{});
      expect(chunk.text, isEmpty);
      expect(chunk.calls, isEmpty);
      expect(chunk.usage, isNull);
    });

    test('Code Assist 的包装与剥壳', () {
      final wrapped = wrapCodeAssistRequest(
        model: 'gemini-2.5-pro',
        project: 'proj-1',
        request: <String, Object?>{'contents': <Object?>[]},
      );
      expect(wrapped['model'], 'gemini-2.5-pro');
      expect(wrapped['project'], 'proj-1');
      expect(wrapped['request'], isA<Map<String, Object?>>());

      expect(
        unwrapCodeAssistResponse(<String, Object?>{
          'response': <String, Object?>{'candidates': <Object?>[]},
        }),
        containsPair('candidates', isEmpty),
      );
      // 不带 response 的事件原样返回，让上层去解。
      expect(
        unwrapCodeAssistResponse(<String, Object?>{'error': 'x'}),
        containsPair('error', 'x'),
      );
    });

    test('联网搜索是 tools 里另一个条目，不是一条函数声明', () {
      const spec =
          ToolSpec('run', 'run it', <String, Object?>{'type': 'object'});

      // 只有搜索。
      expect(
        geminiTools(const <ToolSpec>[], webSearch: true),
        <Map<String, Object?>>[
          <String, Object?>{'google_search': <String, Object?>{}},
        ],
      );

      // 搜索 + 函数声明：两个平级条目，搜索不能钻进 functionDeclarations。
      final both = geminiTools(<ToolSpec>[spec], webSearch: true);
      expect(both, hasLength(2));
      expect(both.first.containsKey('functionDeclarations'), isTrue);
      expect(
          both.last, <String, Object?>{'google_search': <String, Object?>{}});

      // 不开就一条都不加。
      expect(geminiTools(const <ToolSpec>[]), isEmpty);
      expect(geminiTools(<ToolSpec>[spec]), hasLength(1));
    });

    test('搜索来源从 groundingMetadata 里取出来，重复的只留一条', () {
      final chunk = parseGeminiResponse(<String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'text': 'Spain won.'},
              ],
            },
            'groundingMetadata': <String, Object?>{
              'webSearchQueries': <Object?>['UEFA Euro 2024 winner'],
              'groundingChunks': <Object?>[
                <String, Object?>{
                  'web': <String, Object?>{
                    'uri': 'https://redirect/1',
                    'title': 'uefa.com',
                  },
                },
                // 同一个站点被引两次，列表里只该出现一次。
                <String, Object?>{
                  'web': <String, Object?>{
                    'uri': 'https://redirect/1',
                    'title': 'uefa.com',
                  },
                },
                // 没有 uri 的条目跳过，不能变成一条点不开的来源。
                <String, Object?>{
                  'web': <String, Object?>{'title': '只有标题'},
                },
              ],
            },
          },
        ],
      });

      expect(chunk.queries, <String>['UEFA Euro 2024 winner']);
      expect(chunk.sources, hasLength(1));
      expect(chunk.sources.single.title, 'uefa.com');

      final formatted = formatGroundingSources(chunk.sources, chunk.queries);
      expect(formatted, contains('UEFA Euro 2024 winner'));
      expect(formatted, contains('[uefa.com](https://redirect/1)'));

      // 没搜索的那一轮不该凭空多出一个分隔线。
      expect(
          formatGroundingSources(const <GroundingSource>[], const <String>[]),
          isEmpty);
    });

    test('429 里"哪个配额满了"要捞到套话前面来', () {
      const body = '{"error":{"code":429,"message":"You exceeded your current '
          'quota, please check your plan and billing details.",'
          '"status":"RESOURCE_EXHAUSTED","details":['
          '{"@type":"type.googleapis.com/google.rpc.QuotaFailure",'
          '"violations":[{"quotaMetric":"generativelanguage.googleapis.com/'
          'generate_content_free_tier_requests",'
          '"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},'
          '{"@type":"type.googleapis.com/google.rpc.RetryInfo",'
          '"retryDelay":"27s"}]}}';
      final described = describeGoogleQuota(body);
      expect(described,
          contains('GenerateRequestsPerDayPerProjectPerModel-FreeTier'));
      expect(described, contains('27s'));

      // 不是配额错误、或者根本不是 JSON 时不能瞎编。
      expect(describeGoogleQuota('{"error":{"code":503}}'), isEmpty);
      expect(describeGoogleQuota('<html>502 Bad Gateway</html>'), isEmpty);
    });

    test('"搜索和工具不能混用"这条 400 要认出来', () {
      expect(
        isGeminiToolMixError(
          '{"error":{"message":"Multiple tools are supported only when '
          'they are all search tools"}}',
        ),
        isTrue,
      );
      // 别的 400 不能被误判 —— 误判会给出一条完全指错方向的提示。
      expect(isGeminiToolMixError('{"error":{"message":"model not found"}}'),
          isFalse);
    });

    test('SSE 行解析', () {
      expect(decodeSseData('data: {"a":1}'), containsPair('a', 1));
      expect(decodeSseData('data: [DONE]'), isNull);
      expect(decodeSseData(': heartbeat'), isNull);
      expect(decodeSseData('data: not-json'), isNull);
    });
  });

  group('Code Assist 的模型列表', () {
    test('不发请求，直接给内置清单', () async {
      var called = false;
      final models = await fetchModels(
        baseUrl: 'https://cloudcode-pa.googleapis.com/v1internal',
        apiKey: 'token',
        apiFormat: 'gemini',
        client: MockClient((_) async {
          called = true;
          return http.Response('{}', 404);
        }),
      );

      // v1internal 是个 RPC 面，没有 REST 的 /models 集合。照 OpenAI 那套猜
      // 路径只会得到两条 404，而用户看到"获取模型列表失败"会以为是登录或
      // 地址配错了，跑去反复重登。
      expect(called, isFalse, reason: '这一档不该发任何请求');
      expect(models.map((m) => m.id), containsAll(codeAssistModels));
      expect(models, isNotEmpty);
    });

    test('别的协议照旧走网络', () async {
      // 短路只能落在 Code Assist 这一档上 —— 顺手把别人也短路了的话，
      // 那些渠道会永远列不出自己的模型。
      var called = false;
      await fetchModels(
        baseUrl: 'http://gw:3000/v1',
        apiKey: 'k',
        client: MockClient((_) async {
          called = true;
          return http.Response('{"data":[{"id":"glm-5"}]}', 200);
        }),
      );
      expect(called, isTrue);
    });
  });
}
