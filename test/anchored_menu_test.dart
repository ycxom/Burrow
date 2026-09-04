/// 贴着按钮弹出来的浮层菜单。
///
/// 这里钉的是位置：菜单必须**从按钮那一侧长出来，而且不盖住按钮自己**。
/// 弹错边的表现不是"崩了"，是用户点完之后要重新找一遍自己刚才点的是什么 ——
/// 那种别扭很难在事后说清是哪一步出的问题，只能在这里钉死。
library;

import 'package:burrow/src/settings/settings_store.dart';
import 'package:burrow/src/ui/anchored_menu.dart';
import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把一个按钮放在屏幕的指定角落，点它弹菜单。
Widget host({
  required GlobalKey anchor,
  required Alignment corner,
  List<Widget> Function(BuildContext, VoidCallback)? items,
  ChatComposerEffect? material,
}) =>
    MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(
        body: _maybeMaterial(
          material,
          Align(
            alignment: corner,
            child: Builder(
              builder: (context) => IconButton(
                key: anchor,
                icon: const Icon(Icons.add),
                onPressed: () => showAnchoredMenu<void>(
                  context: context,
                  anchor: anchor,
                  builder: items ??
                      (menuContext, refresh) => <Widget>[
                            const MenuAction(
                                icon: Icons.image, label: '从相册选择'),
                            const MenuAction(
                              icon: Icons.auto_awesome,
                              label: '对话模型',
                              detail: '本地网关 · glm-5',
                            ),
                          ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// 有材质就套一层，没有就原样 —— 对应"聊天页里"和"别的地方"两种情况。
Widget _maybeMaterial(ChatComposerEffect? effect, Widget child) =>
    effect == null
        ? child
        : MenuMaterial(
            effect: effect,
            blur: 20,
            opacity: 0.68,
            child: child,
          );

void main() {
  testWidgets('每一项是圆图标 + 一行字，状态写在下面那行小字里', (tester) async {
    final anchor = GlobalKey();
    await tester.pumpWidget(host(anchor: anchor, corner: Alignment.bottomLeft));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    expect(find.text('从相册选择'), findsOneWidget);
    // 设置项的当前值应该在列表里就看得见，点进去才知道等于没说。
    expect(find.text('本地网关 · glm-5'), findsOneWidget);
  });

  testWidgets('按钮在左下角时菜单往上长，不盖住按钮', (tester) async {
    final anchor = GlobalKey();
    await tester.pumpWidget(host(anchor: anchor, corner: Alignment.bottomLeft));
    final button = tester.getRect(find.byKey(anchor));

    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('从相册选择'));
    expect(menu.bottom, lessThan(button.top),
        reason: '往下长就会盖住用户正盯着的那个按钮');
    // 贴着按钮那一侧对齐 —— 长在屏幕另一头的话，手指和视线就分家了。
    expect(menu.left, lessThan(tester.view.physicalSize.width / 2));
  });

  testWidgets('按钮在右上角时菜单往下长', (tester) async {
    final anchor = GlobalKey();
    await tester.pumpWidget(host(anchor: anchor, corner: Alignment.topRight));
    final button = tester.getRect(find.byKey(anchor));

    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('从相册选择'));
    expect(menu.top, greaterThan(button.bottom));
  });

  testWidgets('点空白处关掉', (tester) async {
    final anchor = GlobalKey();
    await tester.pumpWidget(host(anchor: anchor, corner: Alignment.bottomLeft));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();
    expect(find.text('从相册选择'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('从相册选择'), findsNothing);
  });

  testWidgets('菜单里改了东西能当场看到', (tester) async {
    // 终端模式那个开关就靠这个：拨完立刻要看到副标题跟着变，
    // 不然用户会以为没生效然后再拨一次。
    final anchor = GlobalKey();
    var on = false;
    await tester.pumpWidget(host(
      anchor: anchor,
      corner: Alignment.topRight,
      items: (menuContext, refresh) => <Widget>[
        MenuAction(
          icon: Icons.terminal,
          label: '终端模式',
          detail: on ? '模型可以执行命令' : '普通聊天',
          onTap: () {
            on = !on;
            refresh();
          },
        ),
      ],
    ));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();
    expect(find.text('普通聊天'), findsOneWidget);

    await tester.tap(find.text('终端模式'));
    await tester.pumpAndSettle();
    expect(find.text('模型可以执行命令'), findsOneWidget);
  });

  testWidgets('有东西配坏了就在菜单顶上说一句', (tester) async {
    final anchor = GlobalKey();
    await tester.pumpWidget(host(
      anchor: anchor,
      corner: Alignment.bottomLeft,
      items: (menuContext, refresh) => <Widget>[
        const MenuNotice(text: '还没有配对话模型'),
        const MenuAction(icon: Icons.image, label: '从相册选择'),
      ],
    ));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    final notice = tester.getRect(find.text('还没有配对话模型'));
    final first = tester.getRect(find.text('从相册选择'));
    expect(notice.top, lessThan(first.top), reason: '提示要排在最前面才看得见');
  });

  testWidgets('聊天页里的菜单套上输入框那层质感', (tester) async {
    // 用户把输入框调成液态玻璃之后，长按消息弹出来的还是一块实心灰卡 ——
    // 这两样东西在屏幕上只隔着几十像素，不一致一眼就看得出来。
    final anchor = GlobalKey();
    await tester.pumpWidget(host(
      anchor: anchor,
      corner: Alignment.bottomLeft,
      material: ChatComposerEffect.liquid,
    ));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
    expect(surface.effect, ChatComposerEffect.liquid);
    expect(surface.blur, 20);
    expect(surface.opacity, 0.68);
  });

  testWidgets('没配材质时退回实心卡片，菜单照样弹得出来', (tester) async {
    // 这一层是装饰。缺了它菜单照样能用，而为了装饰让菜单弹不出来是本末倒置。
    final anchor = GlobalKey();
    await tester.pumpWidget(host(anchor: anchor, corner: Alignment.bottomLeft));
    await tester.tap(find.byKey(anchor));
    await tester.pumpAndSettle();

    expect(find.byType(GlassSurface), findsNothing);
    expect(find.text('从相册选择'), findsOneWidget);
  });

  testWidgets('长按的位置就是菜单长出来的位置', (tester) async {
    // 气泡上没有按钮，长按的那一下就是用户注意力所在。
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const <ThemeExtension<dynamic>>[
        ChatTokens.dark,
      ]),
      home: Scaffold(body: Builder(builder: (c) {
        ctx = c;
        return const SizedBox.expand();
      })),
    ));

    showAnchoredMenu<void>(
      context: ctx,
      at: const Offset(40, 600),
      builder: (_, __) => <Widget>[
        const MenuAction(icon: Icons.copy, label: '复制'),
      ],
    );
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('复制'));
    expect(menu.bottom, lessThan(600), reason: '触点在下半屏，菜单该往上长');
    expect(menu.left, lessThan(200), reason: '贴着触点那一侧');
  });
}
