import 'dart:io';

import 'package:burrow/src/settings/settings_store.dart';
import 'package:burrow/src/ui/chat_appearance_page.dart';
import 'package:burrow/src/ui/chat_skin.dart';
import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/chat_view.dart';
import 'package:burrow/src/ui/skin_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('聊天外观设置会持久化并可恢复默认值', () async {
    final store = await SettingsStore.load();
    await store.setChatColorStyle(ChatColorStyle.light);
    await store.setChatSkinId('amethyst_glass');
    await store.setChatWallpaperPreset(ChatWallpaperPreset.aurora);
    await store.setChatWallpaperPath('/private/wallpaper.image');
    await store.setChatWallpaperDim(0.35);
    await store.setAssistantAvatarPath('/private/assistant.image');
    await store.setUserAvatarPath('/private/user.image');
    await store.setShowMessageAvatars(false);
    await store.setChatComposerEffect(ChatComposerEffect.frosted);
    await store.setChatComposerBlur(14);
    await store.setChatComposerOpacity(0.55);

    final restored = await SettingsStore.load();
    expect(restored.chatColorStyle, ChatColorStyle.light);
    expect(restored.chatSkinId, 'amethyst_glass');
    expect(restored.chatWallpaperPreset, ChatWallpaperPreset.aurora);
    expect(restored.chatWallpaperPath, '/private/wallpaper.image');
    expect(restored.chatWallpaperDim, 0.35);
    expect(restored.assistantAvatarPath, '/private/assistant.image');
    expect(restored.userAvatarPath, '/private/user.image');
    expect(restored.showMessageAvatars, isFalse);
    expect(restored.chatComposerEffect, ChatComposerEffect.frosted);
    expect(restored.chatComposerBlur, 14);
    expect(restored.chatComposerOpacity, 0.55);

    await restored.resetChatAppearance();
    expect(restored.chatColorStyle, ChatColorStyle.nekogramNight);
    expect(restored.chatSkinId, SettingsStore.defaultChatSkinId);
    expect(restored.chatWallpaperPreset, ChatWallpaperPreset.classic);
    expect(restored.chatWallpaperPath, isEmpty);
    expect(restored.chatWallpaperDim, 0);
    expect(restored.assistantAvatarPath, isEmpty);
    expect(restored.userAvatarPath, isEmpty);
    expect(restored.showMessageAvatars, isTrue);
    expect(restored.chatComposerEffect, ChatComposerEffect.liquid);
    expect(restored.chatComposerBlur, 20);
    expect(restored.chatComposerOpacity, 0.68);
  });

  test('壁纸暗度会限制在安全范围内', () async {
    final store = await SettingsStore.load();
    await store.setChatWallpaperDim(2);
    expect(store.chatWallpaperDim, 0.6);
    await store.setChatWallpaperDim(-1);
    expect(store.chatWallpaperDim, 0);
  });

  test('皮肤 catalog 接受外部包并对失效 ID 回退默认皮肤', () {
    const external = ChatSkinPack(
      id: 'test_external',
      name: '测试皮肤',
      description: '测试 adapter',
      lightTokens: ChatTokens.light,
      darkTokens: ChatTokens.dark,
      previewColors: <Color>[Color(0xFF123456), Color(0xFF654321)],
    );

    expect(
      ChatSkinCatalog.resolve(
        external.id,
        installed: const <ChatSkinPack>[external],
      ),
      same(external),
    );
    expect(
      ChatSkinCatalog.resolve('missing').id,
      SettingsStore.defaultChatSkinId,
    );
  });

  testWidgets('外观页展示即时预览并切换内置壁纸', (tester) async {
    final store = await SettingsStore.load();
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: const <ThemeExtension<dynamic>>[ChatTokens.light],
        ),
        home: ChatAppearancePage(
          store: store,
          // 指向一个不存在的目录：这个用例只关心内置皮肤和壁纸设置，
          // ChatSkinStore.open 没被调用，packs 就是空的。
          skins: ChatSkinStore(root: Directory('.dart_tool/no-skins')),
        ),
      ),
    );

    expect(find.text('Burrow 助手'), findsOneWidget);
    expect(find.text('Nekogram 夜间'), findsOneWidget);
    expect(find.text('皮肤包'), findsOneWidget);
    expect(find.text('紫晶玻璃'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('紫晶玻璃'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('紫晶玻璃'));
    await tester.pump();
    expect(store.chatSkinId, 'amethyst_glass');

    await tester.scrollUntilVisible(
      find.text('极光'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('聊天背景'), findsOneWidget);
    await tester.tap(find.text('极光'));
    await tester.pump();
    expect(store.chatWallpaperPreset, ChatWallpaperPreset.aurora);

    await tester.scrollUntilVisible(
      find.text('悬浮磨砂'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('悬浮磨砂'));
    await tester.pump();
    expect(store.chatComposerEffect, ChatComposerEffect.frosted);
  });

  testWidgets('输入区加号和发送按钮同轴且都能点击', (tester) async {
    final controller = TextEditingController(text: '测试');
    addTearDown(controller.dispose);
    var plusTapped = false;
    var sendTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          extensions: const <ThemeExtension<dynamic>>[ChatTokens.dark],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              controller: controller,
              generating: false,
              enabled: true,
              hintText: '输入消息',
              onSend: () => sendTapped = true,
              onStop: () {},
              safeAreaBottom: false,
              leading: <Widget>[
                ComposerIconButton(
                  icon: Icons.add_rounded,
                  onTap: () => plusTapped = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final plusCenter = tester.getCenter(find.byIcon(Icons.add_rounded));
    final sendCenter = tester.getCenter(find.byIcon(Icons.send_rounded));
    expect((plusCenter.dy - sendCenter.dy).abs(), lessThanOrEqualTo(0.5));

    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(plusTapped, isTrue);
    expect(sendTapped, isTrue);
  });

  testWidgets('发送键跟随文字内容切换状态，空输入不会误触', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sendCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          extensions: const <ThemeExtension<dynamic>>[ChatTokens.dark],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              controller: controller,
              generating: false,
              enabled: true,
              hintText: '输入消息',
              onSend: () => sendCount += 1,
              onStop: () {},
              safeAreaBottom: false,
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('输入内容后发送'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sendCount, 0);

    await tester.enterText(find.byType(TextField), '你好');
    await tester.pumpAndSettle();
    expect(find.byTooltip('发送'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sendCount, 1);
  });

  testWidgets('只有附件时发送键仍可用', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sent = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: const <ThemeExtension<dynamic>>[ChatTokens.light],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              controller: controller,
              generating: false,
              enabled: true,
              hasExternalContent: true,
              hintText: '输入消息',
              onSend: () => sent = true,
              onStop: () {},
              safeAreaBottom: false,
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('发送'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sent, isTrue);
  });

  testWidgets('多行输入平滑扩展输入区高度', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          extensions: const <ThemeExtension<dynamic>>[ChatTokens.light],
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              controller: controller,
              generating: false,
              enabled: true,
              hintText: '输入消息',
              onSend: () {},
              onStop: () {},
              safeAreaBottom: false,
            ),
          ),
        ),
      ),
    );

    final singleLineHeight = tester.getSize(find.byType(ChatComposer)).height;
    await tester.enterText(find.byType(TextField), '第一行\n第二行\n第三行');
    await tester.pumpAndSettle();
    final multiLineHeight = tester.getSize(find.byType(ChatComposer)).height;

    expect(multiLineHeight, greaterThan(singleLineHeight));
  });
}
