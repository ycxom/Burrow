/// 模型选择器里的标星。
///
/// 聚合网关一个 key 后面挂着几十上百个模型，而任何一个人真正会用的就那三五个。
/// 这一组钉的就是那三五个必须**在最前面**，以及标星这件事本身不会顺手把
/// 「选中哪个模型」也一起改了。
@TestOn('vm')
library;

import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/model_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 打开一次选择器，返回它解析出来的结果（没选就是 null）。
  Future<ModelChoice?> open(
    WidgetTester tester, {
    required List<String> models,
    Set<String> starred = const <String>{},
    void Function(String sourceId, String model)? onStar,
  }) async {
    ModelChoice? picked;
    final toggled = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showModelPicker(
                context,
                title: '对话模型',
                current: '',
                sources: <ModelSource>[
                  ModelSource(
                    id: 'c1',
                    name: '本地网关',
                    host: 'gw:3000',
                    models: models,
                    starred: starred,
                  ),
                ],
                activeSourceId: 'c1',
                onRefresh: (_) async => models,
                onToggleStar: (sourceId, model) async {
                  toggled.add(model);
                  onStar?.call(sourceId, model);
                },
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('标过星的排在最前面', (tester) async {
    await open(
      tester,
      models: <String>['a-model', 'b-model', 'c-model', 'd-model'],
      starred: <String>{'c-model'},
    );

    final starredY = tester.getTopLeft(find.text('c-model')).dy;
    for (final other in <String>['a-model', 'b-model', 'd-model']) {
      expect(starredY, lessThan(tester.getTopLeft(find.text(other)).dy),
          reason: '$other 排在标过星的前面了');
    }
  });

  testWidgets('组内保持服务端返回的顺序，不做二次排序', (tester) async {
    // 服务端返回的顺序本身带信息（不少网关把主推的排在前面），
    // 重排一遍等于把那点信息扔了。
    await open(
      tester,
      models: <String>['z-first', 'a-second', 'm-third'],
      starred: <String>{},
    );

    final z = tester.getTopLeft(find.text('z-first')).dy;
    final a = tester.getTopLeft(find.text('a-second')).dy;
    final m = tester.getTopLeft(find.text('m-third')).dy;
    expect(z, lessThan(a));
    expect(a, lessThan(m));
  });

  testWidgets('点星只标星，不会顺手把模型也选了', (tester) async {
    // 星在行的最右边，而整行是"选中这个模型"。点星把弹层关掉并选中，
    // 是这种并排放置最容易出的一个 bug。
    final picked = await open(
      tester,
      models: <String>['a-model', 'b-model'],
    );

    await tester.tap(find.byIcon(Icons.star_border_rounded).first);
    await tester.pumpAndSettle();

    expect(picked, isNull, reason: '弹层不该关掉');
    expect(find.text('a-model'), findsOneWidget, reason: '列表还在');
  });

  testWidgets('标完当场变实心，不用等外面刷新回来', (tester) async {
    // 弹层是一条独立的 route，外面那份状态回到它要走一整圈，走不到。
    await open(tester, models: <String>['a-model']);

    expect(find.byIcon(Icons.star_rounded), findsNothing);
    await tester.tap(find.byIcon(Icons.star_border_rounded).first);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
  });

  testWidgets('标过星但这次没拉回来的模型也要列出来', (tester) async {
    // 网关下架一个模型、或者列表压根没拉动的时候，用户标过的那几个仍然是
    // 他要找的东西 —— 而那恰恰是标星唯一派得上用场的场合。
    await open(
      tester,
      models: <String>['a-model'],
      starred: <String>{'下架了-model'},
    );

    expect(find.text('下架了-model'), findsOneWidget);
    expect(tester.getTopLeft(find.text('下架了-model')).dy,
        lessThan(tester.getTopLeft(find.text('a-model')).dy));
  });

  testWidgets('搜索时不塞进没匹配上的标星模型', (tester) async {
    await open(
      tester,
      models: <String>['a-model', 'b-model'],
      starred: <String>{'下架了-model'},
    );

    await tester.enterText(find.byType(TextField), 'b-');
    await tester.pumpAndSettle();

    // 搜索的意思是"只给我看匹配的"。标星不是豁免权。
    expect(find.text('下架了-model'), findsNothing);
    expect(find.text('b-model'), findsOneWidget);
  });

  testWidgets('没给 onToggleStar 的入口不显示星', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModelPicker(
              context,
              title: '对话模型',
              current: '',
              sources: const <ModelSource>[
                ModelSource(
                  id: 'c1',
                  name: '本地网关',
                  host: 'gw:3000',
                  models: <String>['a-model'],
                ),
              ],
              activeSourceId: 'c1',
              onRefresh: (_) async => <String>['a-model'],
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_border_rounded), findsNothing);
    expect(find.text('a-model'), findsOneWidget);
  });
}
