/// Ubuntu 的 arm64 包不在主线归档路径下，而在 ubuntu-ports 下。
///
/// 真机复现：装好 Ubuntu 后 `apt update` 报
/// `dists/noble/main/binary-arm64/Packages  404  Not Found`。
/// 实测 `mirrors.ustc.edu.cn/ubuntu/.../binary-arm64/Packages.gz` 是 404，
/// 同一台镜像的 `.../ubuntu-ports/.../binary-arm64/...` 是 200。
library;

import 'package:burrow/src/bootstrap/distro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('arm64 走 ubuntu-ports', () {
    test('镜像站换的是路径，主机名不动', () {
      // 这条就是真机上 404 的那个地址。
      expect(
        ubuntuRepoUrlForAbi('http://mirrors.ustc.edu.cn/ubuntu', 'arm64-v8a'),
        'http://mirrors.ustc.edu.cn/ubuntu-ports',
      );
      expect(
        ubuntuRepoUrlForAbi('https://mirrors.nju.edu.cn/ubuntu', 'arm64-v8a'),
        'https://mirrors.nju.edu.cn/ubuntu-ports',
      );
    });

    test('官方主线归档不提供 ports，要整个换主机', () {
      // archive.ubuntu.com 下压根没有 arm64，换路径没用，得换到
      // ports.ubuntu.com 去。
      expect(
        ubuntuRepoUrlForAbi('http://archive.ubuntu.com/ubuntu', 'arm64-v8a'),
        'http://ports.ubuntu.com/ubuntu-ports',
      );
      expect(
        ubuntuRepoUrlForAbi('http://security.ubuntu.com/ubuntu', 'arm64-v8a'),
        'http://ports.ubuntu.com/ubuntu-ports',
      );
    });

    test('x86_64 一个字都不许改', () {
      // amd64 恰恰只在主线归档里有，改成 ports 会把好的配置弄坏。
      expect(
        ubuntuRepoUrlForAbi('http://mirrors.ustc.edu.cn/ubuntu', 'x86_64'),
        'http://mirrors.ustc.edu.cn/ubuntu',
      );
      expect(
        ubuntuRepoUrlForAbi('http://archive.ubuntu.com/ubuntu', 'x86_64'),
        'http://archive.ubuntu.com/ubuntu',
      );
    });

    test('已经是 ports 的保持原样，不会叠成 ubuntu-ports-ports', () {
      expect(
        ubuntuRepoUrlForAbi(
            'http://ports.ubuntu.com/ubuntu-ports/', 'arm64-v8a'),
        'http://ports.ubuntu.com/ubuntu-ports/',
      );
      expect(
        ubuntuRepoUrlForAbi(
            'http://mirrors.ustc.edu.cn/ubuntu-ports', 'arm64-v8a'),
        'http://mirrors.ustc.edu.cn/ubuntu-ports',
      );
    });

    test('整行 deb822 / 传统格式都能改，后面的字段不动', () {
      expect(
        ubuntuRepoUrlForAbi(
            'URIs: http://mirrors.ustc.edu.cn/ubuntu', 'arm64-v8a'),
        'URIs: http://mirrors.ustc.edu.cn/ubuntu-ports',
      );
      // suite 名里带 ubuntu 字样时不能被误伤。
      expect(
        ubuntuRepoUrlForAbi(
            'deb http://mirrors.ustc.edu.cn/ubuntu noble main', 'arm64-v8a'),
        'deb http://mirrors.ustc.edu.cn/ubuntu-ports noble main',
      );
    });
  });
}
