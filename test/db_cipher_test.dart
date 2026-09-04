/// 数据库列加密。
///
/// 这一组里每一条错了都是同一类后果：要么**加密其实没生效**（拿到文件就能
/// 读），要么**数据打不开了**（密钥对但读不出来）。两种都不会报错。
@TestOn('vm')
library;

import 'dart:convert';

import 'package:burrow/src/data/db_cipher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = DbCipher.deriveKey('hunter2', 'fixed-salt');
  final cipher = DbCipher(key);

  group('加解密', () {
    test('转一圈还是原来那句话', () {
      const plain = '帮我看看这台机器的负载，密码是 Qwe23@@##';
      final sealed = cipher.seal(plain);
      expect(cipher.open(sealed), plain);
    });

    test('密文里看不见原文', () {
      const plain = '这是一段不该被看到的对话';
      final sealed = cipher.seal(plain)!;
      // 这就是整件事的意义：拿到 .db 文件的人不该读得出内容。
      expect(sealed, isNot(contains(plain)));
      expect(utf8.decode(base64.decode(sealed.substring(3)), allowMalformed: true),
          isNot(contains(plain)));
    });

    test('同一句话每次加出来都不一样', () {
      // 每次一个新的随机 nonce。相同密文会泄露"这两条消息一模一样"，
      // 而 GCM 在同一密钥下重用 nonce 更是直接把密钥流泄出去。
      final a = cipher.seal('好的');
      final b = cipher.seal('好的');
      expect(a, isNot(b));
      expect(cipher.open(a), '好的');
      expect(cipher.open(b), '好的');
    });

    test('null 原样放行', () {
      // NULL 和"空密文"是两回事：好几列靠 NULL 表示"没设过"。
      expect(cipher.seal(null), isNull);
      expect(cipher.open(null), isNull);
    });

    test('空串也能转一圈', () {
      expect(cipher.open(cipher.seal('')), '');
    });

    test('明文原样放行，不当成坏掉的密文', () {
      // 就地迁移是一行一行走的，中途断电就停在半路 —— 那时库里明文和密文
      // 并存。把明文当错误扔掉的话，用户看到的是"消息没了"。
      expect(cipher.open('还没迁移的一句话'), '还没迁移的一句话');
      expect(DbCipher.isSealed('还没迁移的一句话'), isFalse);
      expect(DbCipher.isSealed(cipher.seal('x')), isTrue);
    });
  });

  group('密钥', () {
    test('密码不对就读不出来，而且不是把乱码当正文', () {
      final wrong = DbCipher(DbCipher.deriveKey('hunter3', 'fixed-salt'));
      final sealed = cipher.seal('机密');
      // GCM 的认证标签保证这里不会把篡改/错密钥的结果当成正常数据读出来。
      expect(wrong.open(sealed), isNull);
    });

    test('盐不一样，同一个密码也开不了', () {
      final other = DbCipher(DbCipher.deriveKey('hunter2', 'another-salt'));
      expect(other.open(cipher.seal('机密')), isNull);
    });

    test('同样的密码 + 同样的盐，派生出同一把钥匙', () {
      // 换手机之后能接着读，全靠这一条 —— 盐跟着数据库走。
      final again = DbCipher(DbCipher.deriveKey('hunter2', 'fixed-salt'));
      expect(again.open(cipher.seal('迁移之后还读得到')), '迁移之后还读得到');
    });

    test('被改过一个字节的密文读不出来', () {
      final sealed = cipher.seal('转账 100 元')!;
      final tampered =
          '${sealed.substring(0, sealed.length - 2)}${sealed.endsWith('A') ? 'B' : 'A'}=';
      expect(cipher.open(tampered), isNull);
    });

    test('十六进制往返之后还是同一把钥匙', () {
      // 日常免输密码靠的是把密钥缓存进系统安全存储，走的就是这条路。
      final back = DbCipher.fromHex(cipher.keyHex)!;
      expect(back.open(cipher.seal('缓存之后还读得到')), '缓存之后还读得到');
    });

    test('坏掉的十六进制读出来是 null', () {
      expect(DbCipher.fromHex(null), isNull);
      expect(DbCipher.fromHex('太短'), isNull);
      expect(DbCipher.fromHex('z' * 64), isNull);
    });

    test('每次生成的盐都不一样', () {
      expect(<String>{for (var i = 0; i < 40; i++) DbCipher.newSalt()},
          hasLength(40));
    });
  });

  group('密码对不对的校验', () {
    test('对的过，错的不过', () {
      final check = DbKeyCheck.make(cipher);
      expect(DbKeyCheck.verify(cipher, check), isTrue);

      final wrong = DbCipher(DbCipher.deriveKey('nope', 'fixed-salt'));
      expect(DbKeyCheck.verify(wrong, check), isFalse);
    });

    test('没存过校验值时不放行', () {
      // 空校验值判成"密码对"的话，任何密码都能开一个空库 ——
      // 而那个库接下来会被用错误的密钥写进去。
      expect(DbKeyCheck.verify(cipher, null), isFalse);
      expect(DbKeyCheck.verify(cipher, ''), isFalse);
    });
  });
}
