import 'package:burrow/src/bootstrap/distro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('沙箱包管理器地址降级', () {
    test('https 换成 http', () {
      // apt/apk 靠签名验证完整性，不靠 TLS —— 这里裁掉的那道握手在它们的
      // 信任模型里本就不必要。真正要挡的是 ubuntu-base 这类精简 rootfs
      // 没有预置 CA 证书链，导致 https 镜像地址在真机上直接报证书错误。
      expect(sandboxPackageUrl('https://mirrors.ustc.edu.cn/ubuntu'),
          'http://mirrors.ustc.edu.cn/ubuntu');
      expect(sandboxPackageUrl('https://deb.debian.org/debian'),
          'http://deb.debian.org/debian');
    });

    test('已经是 http 的不动', () {
      expect(sandboxPackageUrl('http://ports.ubuntu.com/ubuntu-ports'),
          'http://ports.ubuntu.com/ubuntu-ports');
    });

    test('只换协议头，路径原样保留', () {
      expect(
        sandboxPackageUrl(
            'https://mirrors.tuna.tsinghua.edu.cn/debian-security'),
        'http://mirrors.tuna.tsinghua.edu.cn/debian-security',
      );
    });
  });
}
