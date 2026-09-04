/// 数据库里那些**装内容的列**的加解密。
///
/// ## 挡的是什么
///
/// 「有人拿到了 `burrow.db` 这个文件」—— adb pull、送修被拷走、云备份泄露、
/// 旧手机转手。这条路上以前是完全敞开的：一个 sqlite 浏览器就能把几个月的
/// 对话全读出来。
///
/// ## 为什么是列加密，不是 SQLCipher
///
/// SQLCipher 加的是整个文件，连时间戳、条数、索引都盖住，本来更好。但它要
/// 原生库，而桌面上没有 Windows 版 —— 换过去之后这个仓库里五百多个数据库
/// 测试一个都跑不了。**交一个自己验证不了的加密改动，比范围窄一点糟得多。**
///
/// 所以范围要说清楚：正文、思考、标题、摘要、图片路径这些**内容**是密文；
/// 时间戳、角色、条数、id 这些**元数据**仍然是明文。拿到文件的人能看出
/// 「这几天有过一段三百条的对话」，看不出说了什么。
///
/// ## 密钥不落盘
///
/// 密钥由 app 密码派生（PBKDF2，见 [deriveKey]）。备份里只有密文和盐 ——
/// 换手机之后重新输一次密码就能接着读，而**光有备份打不开**。
/// 日常不用反复输：派生出来的密钥缓存在系统安全存储里（那份不跟着备份走，
/// 所以到了新手机上自然会退回"问一次密码"）。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 密文的前缀。
///
/// **必须有**：数据库里会同时存在明文旧行和密文新行（就地迁移是一行一行
/// 走的，中途断电就停在半路）。靠前缀区分，[open] 才能对明文原样放行，
/// 而不是把一段正常的中文当成坏掉的密文扔掉。
///
/// 带版本号是为了以后换算法时还认得出老数据。
const _envelope = 'b1:';

/// PBKDF2 的轮数。
///
/// 比会话锁那道高一档：这一把钥匙开的是整个数据库，而它只在启动时派生
/// 一次（之后缓存在安全存储里），多花的几百毫秒用户一天只碰到一次。
const _iterations = 120000;

class DbCipher {
  DbCipher(this._key)
      : assert(_key.length == 32, '要 256 位密钥');

  final Uint8List _key;

  final Random _random = Random.secure();

  /// 从 app 密码派生密钥。
  ///
  /// 盐跟着数据库走（存在 prefs 里），所以换手机之后同一个密码派生出
  /// 同一把钥匙 —— 这正是"迁移能带着数据走"的全部机制。
  static Uint8List deriveKey(String password, String salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var block = hmac.convert(<int>[...utf8.encode(salt), 0, 0, 0, 1]).bytes;
    final result = List<int>.from(block);
    for (var i = 1; i < _iterations; i++) {
      block = hmac.convert(block).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= block[j];
      }
    }
    return Uint8List.fromList(result);
  }

  static String newSalt([Random? random]) {
    final rng = random ?? Random.secure();
    return List<int>.generate(24, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 密钥的十六进制。只用来缓存进系统安全存储。
  String get keyHex =>
      _key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static DbCipher? fromHex(String? hex) {
    if (hex == null || hex.length != 64) return null;
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      bytes[i] = byte;
    }
    return DbCipher(bytes);
  }

  /// 加密一个值。null 原样放行 —— NULL 和"空密文"是两回事，
  /// 而好几列（system_prompt、summary）靠 NULL 表示"没设过"。
  String? seal(String? plain) {
    if (plain == null) return null;
    // **每次一个新的随机 nonce。** GCM 在同一把密钥下重用 nonce 是灾难性的
    // ——不只是那两条消息，密钥流本身就泄了。
    final nonce = Uint8List.fromList(
      List<int>.generate(12, (_) => _random.nextInt(256)),
    );
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key), 128, nonce, Uint8List(0)));
    final sealed = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    return '$_envelope${base64.encode(<int>[...nonce, ...sealed])}';
  }

  /// 解密一个值。
  ///
  /// **不是密文就原样返回。** 迁移中途的明文行、以及以后可能出现的新格式，
  /// 都靠这一条平稳落地 —— 把它们当成错误抛出去，用户看到的是一个打不开的
  /// app，而实际上数据完好。
  String? open(String? sealed) {
    if (sealed == null || !sealed.startsWith(_envelope)) return sealed;
    try {
      final raw = base64.decode(sealed.substring(_envelope.length));
      if (raw.length <= 12) return sealed;
      final nonce = Uint8List.sublistView(raw, 0, 12);
      final body = Uint8List.sublistView(raw, 12);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(false,
            AEADParameters(KeyParameter(_key), 128, nonce, Uint8List(0)));
      return utf8.decode(cipher.process(body));
    } catch (_) {
      // 密钥不对、或者这一列被改坏了。返回 null 而不是抛：一条读不出来的
      // 消息不该让整个会话打不开。GCM 的认证标签保证这里不会把篡改过的
      // 内容当成正常数据读出来。
      return null;
    }
  }

  /// 这个值是不是已经加密过了。就地迁移用它跳过已经搬完的行。
  static bool isSealed(String? value) =>
      value != null && value.startsWith(_envelope);
}

/// 验证密码对不对，而**不用去试着解一整个数据库**。
///
/// 存一小段已知明文的密文；密码对，就解得开。
/// 比"随便读一条消息看看解不解得开"可靠：新装的 app 里一条消息都没有。
class DbKeyCheck {
  const DbKeyCheck._();

  static const _known = 'burrow-db-key-v1';

  static String make(DbCipher cipher) => cipher.seal(_known)!;

  static bool verify(DbCipher cipher, String? stored) {
    if (stored == null || stored.isEmpty) return false;
    return cipher.open(stored) == _known;
  }
}
