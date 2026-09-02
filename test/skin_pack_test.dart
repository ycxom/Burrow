import 'dart:convert';
import 'dart:io';

import 'package:burrow/src/ui/chat_skin.dart';
import 'package:burrow/src/ui/chat_theme.dart';
import 'package:burrow/src/ui/skin_manifest.dart';
import 'package:burrow/src/ui/skin_parts.dart';
import 'package:burrow/src/ui/skin_store.dart';
import 'package:burrow/src/ui/skin_style.dart';
import 'package:burrow/src/ui/skin_vars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _manifest(Map<String, Object?> extra) => <String, Object?>{
      'schema': 2,
      'id': 'tester.demo',
      'name': '测试皮肤',
      ...extra,
    };

void main() {
  group('表达式求值', () {
    test('四则运算、clamp 与颜色函数', () {
      final vars = SkinVars(<String, Object?>{
        'accent': '#8F83FF',
        'density': 2,
        'pad': 'calc(var(density) * 5 + 1)',
      });
      expect(vars.number('var(pad)'), 11);
      expect(vars.number('clamp(0, 99, 20)'), 20);
      expect(vars.color('var(accent)'), const Color(0xFF8F83FF));
      expect(vars.color('alpha(var(accent), 0.5)')!.a, closeTo(0.5, 0.01));
      expect(vars.color('mix(#000000, #FFFFFF, 1)'), const Color(0xFFFFFFFF));
    });

    test('带单位、颜色参与算术、循环引用都判无效而不是崩', () {
      final vars = SkinVars(<String, Object?>{'a': 'var(b)', 'b': 'var(a)'});
      // 写了单位就整条作废 —— 悄悄读成 16 会让作者以为单位是被支持的。
      expect(vars.number('16px'), isNull);
      // 裸标识符不是变量引用 —— 和 CSS 一样必须写 var(x)。
      expect(SkinVars(<String, Object?>{'x': 3}).number('x * 2'), isNull);
      expect(vars.number('#FF0000 * 2'), isNull);
      expect(vars.number('var(a)'), isNull);
      expect(vars.warnings, isNotEmpty);
    });

    test('未定义的变量只影响用到它的那个属性', () {
      final vars = SkinVars(<String, Object?>{'known': 4});
      expect(vars.number('var(unknown)'), isNull);
      expect(vars.number('var(known)'), 4);
    });
  });

  group('manifest 解析', () {
    test('稀疏合并：没写的令牌保持基座值', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'tokens': <String, Object?>{
          'dark': <String, Object?>{'brand': '#8F83FF'},
        },
      }));
      expect(result.ok, isTrue);
      expect(result.pack!.darkTokens.brand, const Color(0xFF8F83FF));
      expect(result.pack!.darkTokens.bubbleIn, ChatTokens.dark.bubbleIn);
      // 只写了 dark，light 整套保持基座。
      expect(result.pack!.lightTokens.brand, ChatTokens.light.brand);
    });

    test('拼错的令牌名只丢那一个键，其余照常生效', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'tokens': <String, Object?>{
          'dark': <String, Object?>{
            'brandd': '#8F83FF',
            'bubbleOut': '#514787',
          },
        },
      }));
      expect(result.ok, isTrue);
      expect(result.pack!.darkTokens.bubbleOut, const Color(0xFF514787));
      expect(result.warnings.any((w) => w.contains('brandd')), isTrue);
    });

    test('schema 比当前新则整包拒绝', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'schema': SkinManifest.currentSchema + 1,
      }));
      expect(result.ok, isFalse);
    });

    test('外部包不能占用内置 ID，也必须带命名空间', () {
      expect(
        SkinManifest.parse(<String, Object?>{
          'id': 'nekogram',
          'name': 'x',
        }).ok,
        isFalse,
      );
      expect(
        SkinManifest.parse(<String, Object?>{'id': 'dark', 'name': 'x'}).ok,
        isFalse,
      );
      expect(SkinManifest.parse(_manifest(const {})).ok, isTrue);
    });

    test('extends 只认内置皮肤，指错了回落默认而不是失败', () {
      final good = SkinManifest.parse(
        _manifest(<String, Object?>{'extends': 'amethyst_glass'}),
      );
      expect(good.pack!.darkTokens.brand, const Color(0xFF8F83FF));

      final bad = SkinManifest.parse(
        _manifest(<String, Object?>{'extends': 'someone.else'}),
      );
      expect(bad.ok, isTrue);
      expect(bad.pack!.darkTokens.brand, ChatTokens.dark.brand);
      expect(bad.warnings, isNotEmpty);
    });

    test('把文字和背景写成同色的皮肤装不上', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'tokens': <String, Object?>{
          'dark': <String, Object?>{
            'tintPrimary': '#111111',
            'bgPrimary': '#111111',
          },
        },
      }));
      expect(result.ok, isFalse);
      expect(result.errors.first, contains('对比度'));
    });

    test('导出再导入，令牌逐一相等', () {
      final source = ChatSkinCatalog.builtIns
          .firstWhere((s) => s.id == 'amethyst_glass');
      final round = SkinManifest.parse(_manifest(<String, Object?>{
        'tokens': <String, Object?>{
          'light': SkinManifest.exportTokens(source.lightTokens),
          'dark': SkinManifest.exportTokens(source.darkTokens),
        },
      }));
      expect(round.ok, isTrue);
      for (final name in ChatTokens.tokenNames) {
        expect(round.pack!.darkTokens.named(name), source.darkTokens.named(name),
            reason: name);
        expect(
            round.pack!.lightTokens.named(name), source.lightTokens.named(name),
            reason: name);
      }
    });
  });

  group('部件与继承', () {
    ChatSkinParts partsOf(Map<String, Object?> parts, {Brightness? mode}) {
      final result = SkinManifest.parse(
        _manifest(<String, Object?>{'parts': parts}),
      );
      expect(result.ok, isTrue, reason: result.errors.join('\n'));
      return result.pack!.partsFor(mode ?? Brightness.dark);
    }

    test('bubble 是抽象基，属性流到 in/out/error', () {
      final parts = partsOf(<String, Object?>{
        'bubble': <String, Object?>{'radius': 20},
        'bubble.out': <String, Object?>{'background': '#514787'},
      });
      expect(parts.bubbleIn.radius?.maxRadius, 20);
      expect(parts.bubbleOut.radius?.maxRadius, 20);
      expect(parts.bubbleError.radius?.maxRadius, 20);
      expect(parts.bubbleOut.fillColor(), const Color(0xFF514787));
      expect(parts.bubbleIn.fillColor(), isNull);
    });

    test('header 和 header.title 互不继承', () {
      final parts = partsOf(<String, Object?>{
        'header': <String, Object?>{'background': '#101010'},
      });
      expect(parts.header.fillColor(), const Color(0xFF101010));
      expect(parts.headerTitle.fillColor(), isNull);
    });

    test('状态修饰符合成为完整样式，取用是一次数组下标', () {
      final parts = partsOf(<String, Object?>{
        'bubble': <String, Object?>{'radius': 14},
        'bubble.out:first': <String, Object?>{
          'radius': <String, Object?>{'tr': 4},
        },
      });
      final first = parts.bubbleOut.on(SkinState.first)!;
      // 状态样式是完整的：没被覆盖的角还是继承来的 14。
      expect(first.radius?.tr, 4);
      expect(first.radius?.tl, 14);
      expect(parts.bubbleOut.on(SkinState.last), isNull);
    });

    test('明暗修饰符在解析时就摊平成两套', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'parts': <String, Object?>{
          'header:dark': <String, Object?>{'background': '#000000'},
          'header:light': <String, Object?>{'background': '#FFFFFF'},
        },
      }));
      expect(result.pack!.darkParts.header.fillColor(),
          const Color(0xFF000000));
      expect(result.pack!.lightParts.header.fillColor(),
          const Color(0xFFFFFFFF));
    });

    test('版式枚举与未知取值', () {
      final parts = partsOf(<String, Object?>{
        'layout': <String, Object?>{
          'bubble': 'card',
          'composer': 'docked',
          'time': 'outside',
        },
      });
      expect(parts.bubbleLayout, SkinBubbleLayout.card);
      expect(parts.composerMode, SkinComposerMode.docked);
      expect(parts.timePosition, SkinTimePosition.outside);

      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'parts': <String, Object?>{
          'layout': <String, Object?>{'bubble': 'spaceship'},
        },
      }));
      expect(result.ok, isTrue);
      expect(result.pack!.darkParts.bubbleLayout, SkinBubbleLayout.tail);
      expect(result.warnings, isNotEmpty);
    });

    test('资源路径逃逸被丢弃', () {
      final result = SkinManifest.parse(
        _manifest(<String, Object?>{
          'parts': <String, Object?>{
            'shell.background': <String, Object?>{
              'background': <String, Object?>{'image': '../../../etc/passwd'},
            },
          },
        }),
        assetRoot: '/tmp/skin',
      );
      expect(result.pack!.darkParts.shellBackground.image, isNull);
    });
  });

  group('必留部件', () {
    ChatSkinParts hostile(Map<String, Object?> drawer) {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'parts': <String, Object?>{'header.drawer': drawer},
      }));
      expect(result.ok, isTrue);
      return result.pack!.darkParts;
    }

    test('visible: false 被忽略', () {
      expect(hostile(<String, Object?>{'visible': false}).headerDrawer.hidden,
          isFalse);
    });

    test('opacity 归零被钳到仍然看得见', () {
      final style = hostile(<String, Object?>{'opacity': 0}).headerDrawer;
      expect(style.opacity, greaterThanOrEqualTo(0.55));
    });

    test('尺寸归零被钳到最小可触达', () {
      final style = hostile(<String, Object?>{'size': 1}).headerDrawer;
      expect(style.size, greaterThanOrEqualTo(PartStyle.minTapTarget));
    });

    test('推出屏幕的位移被钳回原位附近', () {
      final style = hostile(<String, Object?>{
        'transform': <String, Object?>{'dx': -9999, 'scale': 0.01},
      }).headerDrawer;
      expect(style.transform!.dx, greaterThanOrEqualTo(-12));
      expect(style.transform!.scale, greaterThanOrEqualTo(0.75));
    });

    test('图标缩到看不见也被钳住', () {
      final style = hostile(<String, Object?>{
        'icon': <String, Object?>{'name': 'menu', 'size': 0},
      }).headerDrawer;
      expect(style.icon!.size, greaterThanOrEqualTo(14));
    });

    test('输入框同样受钳制', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'parts': <String, Object?>{
          'composer.field': <String, Object?>{'visible': false, 'opacity': 0},
        },
      }));
      final style = result.pack!.darkParts.composerField;
      expect(style.hidden, isFalse);
      expect(style.opacity, greaterThanOrEqualTo(0.55));
    });

    test('非必留部件可以正常隐藏', () {
      final result = SkinManifest.parse(_manifest(<String, Object?>{
        'parts': <String, Object?>{
          'date.pill': <String, Object?>{'visible': false},
        },
      }));
      expect(result.pack!.darkParts.datePill.hidden, isTrue);
    });
  });

  group('磁盘层', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('burrow-skins');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('从 JSON 文本安装、读回、卸载', () async {
      final store = ChatSkinStore(root: root);
      await store.open();
      expect(store.packs, isEmpty);

      final pack = await store.installFromJson(jsonEncode(_manifest(
        <String, Object?>{
          'tokens': <String, Object?>{
            'dark': <String, Object?>{'brand': '#8F83FF'},
          },
        },
      )));
      expect(pack.id, 'tester.demo');
      expect(store.packs, hasLength(1));

      // 磁盘是唯一真相：重新打开一个 store 要能读到同一个包。
      final reopened = ChatSkinStore(root: root);
      await reopened.open();
      expect(reopened.packs.single.id, 'tester.demo');
      expect(reopened.packs.single.darkTokens.brand, const Color(0xFF8F83FF));

      await reopened.uninstall('tester.demo');
      expect(reopened.packs, isEmpty);
      expect(root.listSync().whereType<Directory>(), isEmpty);
    });

    test('装不上的包会被拒绝，磁盘上不留半个目录', () async {
      final store = ChatSkinStore(root: root);
      await store.open();
      await expectLater(
        store.installFromJson('{ not json'),
        throwsA(isA<SkinInstallException>()),
      );
      expect(store.packs, isEmpty);
    });

    test('坏掉的目录被报出来而不是静默消失', () async {
      final dir = Directory('${root.path}/broken')..createSync(recursive: true);
      File('${dir.path}/skin.json').writeAsStringSync('{ oops');
      final store = ChatSkinStore(root: root);
      await store.open();
      expect(store.packs, isEmpty);
      expect(store.broken.single.directory, 'broken');

      await store.removeBroken('broken');
      expect(store.broken, isEmpty);
    });

    test('ID 里的斜杠不会变成嵌套目录', () async {
      final store = ChatSkinStore(root: root);
      await store.open();
      await store.installFromJson(jsonEncode(<String, Object?>{
        'schema': 2,
        'id': 'tester/nested',
        'name': '斜杠',
      }));
      final reopened = ChatSkinStore(root: root);
      await reopened.open();
      expect(reopened.packs.single.id, 'tester/nested');
    });
  });

  group('catalog', () {
    test('外部包不能覆盖内置 ID', () {
      const impostor = ChatSkinPack(
        id: 'nekogram',
        name: '冒牌',
        description: '',
        lightTokens: ChatTokens.light,
        darkTokens: ChatTokens.dark,
        previewColors: <Color>[],
      );
      final resolved =
          ChatSkinCatalog.resolve('nekogram', installed: <ChatSkinPack>[impostor]);
      expect(resolved.name, 'Nekogram 经典');
    });

    test('未知 ID 回落默认皮肤', () {
      expect(ChatSkinCatalog.resolve('gone.forever').id,
          ChatSkinCatalog.fallback.id);
    });
  });
}
