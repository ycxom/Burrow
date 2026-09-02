/// 皮肤包的变量层。
///
/// 这是「像 CSS 一样」的那一半：皮肤包在 `vars` 里声明一批命名值，之后所有
/// 颜色和数字都可以写成 `var(accent)`、`calc(density * 10)`。
///
/// **求值结果只可能是数或颜色。** 没有布尔、没有字符串拼接、没有条件、没有
/// 循环、没有用户自定义函数 —— 皮肤包是数据，不是脚本。这条边界不是洁癖：
/// 一旦表达式能表达控制流，「加载一个皮肤包」就等于「执行一段别人写的
/// 代码」，而皮肤包是要在网上互相传的。
///
/// 语法（递归下降，见 [_ExprParser]）：
///
///     expr   := term (('+' | '-') term)*
///     term   := factor (('*' | '/') factor)*
///     factor := number | hex | '(' expr ')' | call | '-' factor
///     call   := ident '(' args? ')'
///
/// 可用函数只有这些，且全部是纯函数：
///
///   - `var(name)` 取变量。参数是裸标识符，不是表达式。
///   - `calc(expr)` 只为可读性存在，等价于括号。
///   - `clamp(lo, x, hi)` / `min(a, b)` / `max(a, b)`
///   - `alpha(color, a)` 改透明度
///   - `mix(colorA, colorB, t)` 线性混色
///   - `lighten(color, t)` / `darken(color, t)`
library;

import 'dart:ui' show Color;

/// 一份已声明的变量表，带惰性求值和循环引用检测。
///
/// 惰性而不是加载时全量展开：变量之间可以互相引用，而声明顺序就是 JSON
/// 对象的顺序 —— 要求作者"先声明后使用"是没必要的摩擦。
class SkinVars {
  SkinVars([Map<String, Object?> declared = const <String, Object?>{}])
      : _declared = Map<String, Object?>.of(declared);

  final Map<String, Object?> _declared;
  final Map<String, Object?> _resolved = <String, Object?>{};

  /// 正在求值的变量名。用来在 `a: var(b)` / `b: var(a)` 时切断递归 ——
  /// 否则解析一个手写错的皮肤包会直接栈溢出。
  final Set<String> _resolving = <String>{};

  /// 求值过程中发现的问题。**不抛异常**：单个变量写错应该只让用到它的那个
  /// 属性回落基座值，而不是让整个皮肤包装不上。
  final List<String> warnings = <String>[];

  static SkinVars get empty => SkinVars();

  Object? _lookup(String name) {
    if (_resolved.containsKey(name)) return _resolved[name];
    if (!_declared.containsKey(name)) {
      warnings.add('未定义的变量 var($name)');
      return null;
    }
    if (!_resolving.add(name)) {
      warnings.add('变量 $name 存在循环引用');
      return null;
    }
    final value = eval(_declared[name]);
    _resolving.remove(name);
    _resolved[name] = value;
    return value;
  }

  /// 求一个原始 JSON 值。数字直接过，字符串走表达式解析器。
  Object? eval(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is! String) return null;
    final text = raw.trim();
    if (text.isEmpty) return null;
    final value = _ExprParser(text, this).parse();
    if (value == null) warnings.add('无法求值的表达式：$raw');
    return value;
  }

  /// 求一个数。求出来是颜色的话按"写错了"处理，返回 null 让调用方回落。
  double? number(Object? raw) {
    final value = eval(raw);
    return value is double && value.isFinite ? value : null;
  }

  Color? color(Object? raw) {
    final value = eval(raw);
    return value is Color ? value : null;
  }

  /// 直接解析一个颜色字面量，不走变量表。给内置皮肤和测试用。
  static Color? parseColor(String text) => _parseHex(text.trim());
}

/// `#RRGGBB` / `#AARRGGBB`，别的一律不认。
///
/// 不支持 `rgb()`、颜色关键字和 `#RGB` 简写是刻意的：能表达同一个颜色的写法
/// 越多，「两个皮肤包看起来该一样却不一样」的调试就越难，而收益只是少敲几个
/// 字符。
Color? _parseHex(String text) {
  if (!text.startsWith('#')) return null;
  final hex = text.substring(1);
  if (hex.length != 6 && hex.length != 8) return null;
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(hex.length == 6 ? 0xFF000000 | value : value);
}

class _ExprParser {
  _ExprParser(this._src, this._vars);

  final String _src;
  final SkinVars _vars;
  int _pos = 0;

  Object? parse() {
    final value = _expr();
    _skip();
    // 有残留字符说明整条表达式写错了（比如 `16px`）。宁可整条作废回落基座，
    // 也不要把 `16px` 悄悄读成 16 —— 那会让作者以为单位是被支持的。
    return _pos == _src.length ? value : null;
  }

  void _skip() {
    while (_pos < _src.length && _src.codeUnitAt(_pos) <= 0x20) {
      _pos++;
    }
  }

  bool _eat(String ch) {
    _skip();
    if (_pos < _src.length && _src[_pos] == ch) {
      _pos++;
      return true;
    }
    return false;
  }

  Object? _expr() {
    var left = _term();
    while (true) {
      _skip();
      if (_pos >= _src.length) return left;
      final op = _src[_pos];
      if (op != '+' && op != '-') return left;
      _pos++;
      left = _arith(left, _term(), op);
    }
  }

  Object? _term() {
    var left = _factor();
    while (true) {
      _skip();
      if (_pos >= _src.length) return left;
      final op = _src[_pos];
      if (op != '*' && op != '/') return left;
      _pos++;
      left = _arith(left, _factor(), op);
    }
  }

  /// 四则运算只对数字成立。颜色参与算术没有良好定义（`#FF0000 * 2` 该是
  /// 什么？），直接判无效，让作者去用 `mix` / `lighten`。
  Object? _arith(Object? left, Object? right, String op) {
    if (left is! double || right is! double) return null;
    return switch (op) {
      '+' => left + right,
      '-' => left - right,
      '*' => left * right,
      '/' => right == 0 ? null : left / right,
      _ => null,
    };
  }

  Object? _factor() {
    _skip();
    if (_pos >= _src.length) return null;

    if (_eat('(')) {
      final value = _expr();
      return _eat(')') ? value : null;
    }
    if (_eat('-')) {
      final value = _factor();
      return value is double ? -value : null;
    }

    final ch = _src[_pos];
    if (ch == '#') return _hex();
    if (_isDigit(ch) || ch == '.') return _number();
    if (_isIdentStart(ch)) return _call();
    return null;
  }

  Object? _hex() {
    final start = _pos;
    _pos++;
    while (_pos < _src.length && _isHex(_src[_pos])) {
      _pos++;
    }
    return _parseHex(_src.substring(start, _pos));
  }

  Object? _number() {
    final start = _pos;
    var seenDot = false;
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (_isDigit(ch)) {
        _pos++;
      } else if (ch == '.' && !seenDot) {
        seenDot = true;
        _pos++;
      } else {
        break;
      }
    }
    return double.tryParse(_src.substring(start, _pos));
  }

  String _ident() {
    final start = _pos;
    while (_pos < _src.length && _isIdentPart(_src[_pos])) {
      _pos++;
    }
    return _src.substring(start, _pos);
  }

  Object? _call() {
    final name = _ident();
    if (!_eat('(')) return null;

    // var 的参数是裸标识符而不是表达式 —— 变量名是名字，不是值。
    if (name == 'var') {
      _skip();
      final target = _ident();
      if (target.isEmpty || !_eat(')')) return null;
      return _vars._lookup(target);
    }

    final args = <Object?>[];
    if (!_eat(')')) {
      do {
        args.add(_expr());
      } while (_eat(','));
      if (!_eat(')')) return null;
    }

    double? asNum(int i) =>
        i < args.length && args[i] is double ? args[i] as double : null;
    Color? asColor(int i) =>
        i < args.length && args[i] is Color ? args[i] as Color : null;

    switch (name) {
      case 'calc':
        return args.length == 1 ? args[0] : null;
      case 'clamp':
        final lo = asNum(0), x = asNum(1), hi = asNum(2);
        if (lo == null || x == null || hi == null || lo > hi) return null;
        return x.clamp(lo, hi).toDouble();
      case 'min':
        final a = asNum(0), b = asNum(1);
        return a == null || b == null ? null : (a < b ? a : b);
      case 'max':
        final a = asNum(0), b = asNum(1);
        return a == null || b == null ? null : (a > b ? a : b);
      case 'alpha':
        final c = asColor(0), a = asNum(1);
        return c == null || a == null
            ? null
            : c.withValues(alpha: a.clamp(0.0, 1.0).toDouble());
      case 'mix':
        final a = asColor(0), b = asColor(1), t = asNum(2);
        return a == null || b == null || t == null
            ? null
            : Color.lerp(a, b, t.clamp(0.0, 1.0).toDouble());
      case 'lighten':
        final c = asColor(0), t = asNum(1);
        return c == null || t == null
            ? null
            : Color.lerp(
                c, const Color(0xFFFFFFFF), t.clamp(0.0, 1.0).toDouble());
      case 'darken':
        final c = asColor(0), t = asNum(1);
        return c == null || t == null
            ? null
            : Color.lerp(
                c, const Color(0xFF000000), t.clamp(0.0, 1.0).toDouble());
      default:
        return null;
    }
  }

  static bool _isDigit(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39;
  }

  static bool _isHex(String c) {
    final u = c.toLowerCase().codeUnitAt(0);
    return (u >= 0x30 && u <= 0x39) || (u >= 0x61 && u <= 0x66);
  }

  static bool _isIdentStart(String c) {
    final u = c.toLowerCase().codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7A) || c == '_';
  }

  static bool _isIdentPart(String c) {
    final u = c.toLowerCase().codeUnitAt(0);
    return (u >= 0x61 && u <= 0x7A) ||
        (u >= 0x30 && u <= 0x39) ||
        c == '_' ||
        c == '-';
  }
}
