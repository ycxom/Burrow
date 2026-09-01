import 'package:burrow/src/settings/settings_store.dart';
import 'package:burrow/src/ui/chat_appearance_page.dart';
import 'package:burrow/src/ui/chat_theme.dart';
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
        home: ChatAppearancePage(store: store),
      ),
    );

    expect(find.text('Burrow 助手'), findsOneWidget);
    expect(find.text('夜间'), findsOneWidget);
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
}
