/// 可选择的发行版基座。
///
/// ## 为什么换掉自建 Termux bootstrap
///
/// 原方案要 fork termux-packages、以 `TERMUX_APP_PACKAGE=com.burrow`
/// 重编整套包 —— 因为 Termux 的二进制把 `/data/data/com.termux/files/usr`
/// 硬编码进去了。那是一条要长期维护的构建流水线。
///
/// 换成发行版 rootfs 之后这个问题**自己消失了**：Ubuntu / Debian / Alpine
/// 的二进制硬编码的是 `/usr`、`/lib`、`/etc` 这些标准 FHS 路径，
/// 而 proot 的 `-r <rootfs>` 正是把这些路径重定向到我们目录下的机制。
/// 不需要重编任何东西，官方 base tarball 直接可用。
///
/// 附带的好处：
///   - 完整的 apt / apk 生态，不用维护自己的软件源
///   - 用户可以按需选发行版（想要 3MB 的 Alpine 还是 apt 齐全的 Debian）
///   - 回滚更干净：每个发行版就是一个目录，「代目录 + 原子 rename」
///     天然适用（见 PrefixGenerations）
///
/// 代价：
///   - 必须有 proot（ptrace 实现，重 I/O 下慢 20~40%）
///   - 首次要联网下载 rootfs（Alpine 3MB / Debian 30MB / Ubuntu 30MB）
///   - 装不进 APK —— 三个发行版加起来太大，只能运行时拉
///
/// ## 为什么默认 Alpine
///
/// 3MB 下载、8MB 解开、约 200 个文件。在手机上首次启动体验差距是数量级的
/// （Debian base 有 12000+ 文件，解压要一分多钟）。musl 的兼容性问题在
/// 「跑脚本和命令行工具」这个用途下基本碰不到；真需要 glibc 时再切 Debian。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'tar_reader.dart';

enum MirrorRegion { china, international }

/// rootfs 下载地址与安装后的包管理器地址必须成对切换。
class DistroSource {
  final String id;
  final String displayName;
  final MirrorRegion region;
  final Map<String, String> rootfsUrls;
  final String packageBaseUrl;

  const DistroSource({
    required this.id,
    required this.displayName,
    required this.region,
    required this.rootfsUrls,
    required this.packageBaseUrl,
  });
}

/// 一个可选的发行版。
class Distro {
  /// 稳定标识，用作目录名。带版本 —— 同时装 debian-12 和 debian-13 应该能共存。
  final String id;

  final String displayName;
  final String description;

  /// 按 ABI 给出 rootfs tarball 的地址。key 是 Android 的 ABI 名。
  final Map<String, String> rootfsUrls;

  /// 可由用户选择的下载源。空列表时使用 [rootfsUrls]。
  final List<DistroSource> sources;

  /// 按 ABI 给出 sha256。**不是可选项** —— 这是从网上下一坨东西然后
  /// 在里面执行代码，不校验等于把设备交给任何能劫持这条连接的人。
  /// 前面已经实测过本机的 DNS 是被污染的。
  final Map<String, String> sha256;

  /// 解开后的大致大小，装之前告诉用户。
  final int approxInstalledBytes;

  /// 这个发行版里包管理器的名字，ExecPolicy 和提示词要用。
  final String packageManager;

  /// 非 null 表示这一项**在所有 ABI 上都装不了**，值就是原因。
  ///
  /// 用一个显式字段而不是让用户点下去再报错：点击后失败会让人以为是
  /// 网络问题反复重试，而这里的不可用是确定性的、和网络无关的。
  final String? blockedReason;

  /// 只在特定 ABI 上不可用。key 是 ABI 名，value 是原因。
  ///
  /// 分开是因为「能不能用」真的会随架构变 —— 见 Alpine 在 x86_64 上的
  /// musl/seccomp 问题。一刀切标成不可用会白白挡掉真机上完全能用的选项。
  final Map<String, String> abiBlockedReasons;

  /// 在这个 ABI 上不可用的原因；null = 可用。
  String? blockedReasonFor(String abi) =>
      blockedReason ?? abiBlockedReasons[abi];

  bool isAvailableOn(String abi) => blockedReasonFor(abi) == null;

  const Distro({
    required this.id,
    required this.displayName,
    required this.description,
    required this.rootfsUrls,
    this.sources = const [],
    required this.sha256,
    required this.approxInstalledBytes,
    required this.packageManager,
    this.blockedReason,
    this.abiBlockedReasons = const {},
  });

  bool supports(String abi) => rootfsUrls.containsKey(abi);

  DistroSource? defaultSource(MirrorRegion region) {
    for (final source in sources) {
      if (source.region == region) return source;
    }
    return sources.isEmpty ? null : sources.first;
  }
}

/// 内置目录。
///
/// URL 和校验和写死在代码里而不是从服务器拉一个「目录文件」：
/// 一个可远程更新的目录等于给自己开了一个「换掉用户 rootfs 来源」的后门，
/// 而这个 app 的全部意义就是在受控环境里跑不受信任的代码。
/// 要加发行版就发版本更新。
class DistroCatalog {
  static const alpine = Distro(
    id: 'alpine-3.21',
    displayName: 'Alpine 3.21',
    description: '最小。3MB 下载 / 8MB 解开，约 200 个文件，首次安装几秒。'
        'musl libc，包管理器 apk。适合脚本和命令行工具。',
    rootfsUrls: {
      'arm64-v8a':
          'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
      'x86_64':
          'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz',
    },
    sources: [
      DistroSource(
          id: 'alpine-ustc',
          displayName: '中科大 USTC',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.ustc.edu.cn/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://mirrors.ustc.edu.cn/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.ustc.edu.cn/alpine'),
      // TUNA 放在 USTC 之后而不是第一个：实测这台机器上
      // mirrors.tuna.tsinghua.edu.cn 对 alpine / ubuntu-cdimage 两个路径
      // 都返回 403（页面明说「您目前无法访问此页面」），像是按来源 IP 拦的。
      // 换个网络多半是通的，所以不删掉它，只是不再当默认 ——
      // 默认源应该选一个「几乎不会拒绝任何人」的。
      DistroSource(
          id: 'alpine-tuna',
          displayName: '清华 TUNA',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.tuna.tsinghua.edu.cn/alpine'),
      DistroSource(
          id: 'alpine-nju',
          displayName: '南京大学 NJU',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.nju.edu.cn/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://mirrors.nju.edu.cn/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.nju.edu.cn/alpine'),
      DistroSource(
          id: 'alpine-official',
          displayName: 'Alpine 官方 CDN',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://dl-cdn.alpinelinux.org/alpine'),
      DistroSource(
          id: 'alpine-princeton',
          displayName: 'Princeton',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirror.math.princeton.edu/pub/alpinelinux/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://mirror.math.princeton.edu/pub/alpinelinux/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://mirror.math.princeton.edu/pub/alpinelinux'),
      DistroSource(
          id: 'alpine-rwth',
          displayName: 'RWTH Aachen',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://ftp.halifax.rwth-aachen.de/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz',
            'x86_64':
                'https://ftp.halifax.rwth-aachen.de/alpine/v3.21/releases/x86_64/alpine-minirootfs-3.21.0-x86_64.tar.gz'
          },
          packageBaseUrl: 'https://ftp.halifax.rwth-aachen.de/alpine'),
    ],
    // 取自官方 .tar.gz.sha256；x86_64 那条已用实际下载的文件复核过。
    sha256: {
      'arm64-v8a':
          'f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1',
      'x86_64':
          '55ea3e5a7c2c35e6268c5dcbb8e45a9cd5b0e372e7b4e798499a526834f7ed90',
    },
    approxInstalledBytes: 8 * 1024 * 1024,
    packageManager: 'apk',
    // musl 在有 `fork` 系统调用的架构上直接用它（x86_64 的 SYS_fork=57），
    // 而 Android 给 app 进程装的 zygote seccomp 策略不放行裸 fork
    // —— bionic 一律走 clone，所以那条路从来没被放进白名单。
    // 结果是 rootfs 里任何要 fork 的命令都返回 ENOSYS：
    //   /bin/sh: can't fork: Function not implemented
    //
    // aarch64 的系统调用表里**根本没有 fork**（只有 clone），musl 只能用
    // clone，所以真机 arm64 完全正常 —— 实测确认过 NDK 头文件里
    // aarch64 无 __NR_fork，x86_64/armv7a/i686 都有。
    //
    // x86_64 Android 基本只出现在模拟器上，所以这条主要影响开发体验。
    // 那种场景下 Ubuntu（glibc，fork 走 clone）是可用的替代。
    abiBlockedReasons: {
      'x86_64': 'musl 在 x86_64 上用裸 fork 系统调用，'
          '被 Android 的 app seccomp 策略拦下（真机 arm64 不受影响）',
    },
  );

  static const debian = Distro(
    id: 'debian-12',
    displayName: 'Debian 12 (bookworm)',
    description: '30MB 下载 / 120MB 解开，约 12000 个文件。'
        'glibc，包管理器 apt。兼容性最好，预编译二进制基本都能跑。',
    rootfsUrls: {
      'arm64-v8a':
          'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/fb7215b47dab72bdbdd59204a7b7914311431d90/bookworm/rootfs.tar.xz',
      'x86_64':
          'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/2b9b380c71ad8a3b6ce55c083c9ecfb901dabf71/bookworm/rootfs.tar.xz',
    },
    sources: [
      DistroSource(
          id: 'debian-github-cn',
          displayName: 'Debian 官方构建（大陆线路）',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/fb7215b47dab72bdbdd59204a7b7914311431d90/bookworm/rootfs.tar.xz',
            'x86_64':
                'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/2b9b380c71ad8a3b6ce55c083c9ecfb901dabf71/bookworm/rootfs.tar.xz'
          },
          packageBaseUrl: 'https://mirrors.tuna.tsinghua.edu.cn/debian'),
      DistroSource(
          id: 'debian-github',
          displayName: 'Debian 官方构建',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/fb7215b47dab72bdbdd59204a7b7914311431d90/bookworm/rootfs.tar.xz',
            'x86_64':
                'https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/2b9b380c71ad8a3b6ce55c083c9ecfb901dabf71/bookworm/rootfs.tar.xz'
          },
          packageBaseUrl: 'https://deb.debian.org/debian'),
    ],
    sha256: {
      'arm64-v8a':
          '202ecca447dbf1b3ac1b1e983d9363381ac6a34f8e22d7d786125d06754ebb76',
      'x86_64':
          '6d823876698ad6e575a82fddf4166fe4d8c326698e01f8f9aafac64004b6dc44',
    },
    approxInstalledBytes: 120 * 1024 * 1024,
    packageManager: 'apt',
    // debuerreotype/docker-debian-artifacts 已经不在仓库里存 rootfs.tar.xz 了
    // （改成了 oci/ 布局），上面这两个 pin 死的 commit 现在一律 404 ——
    // commit 本身还在，只是那个路径下没有这个文件。实测：
    //   raw.githubusercontent.com/.../<sha>/bookworm/rootfs.tar.xz  → 404
    //   github.com/.../raw/dist-amd64/bookworm/rootfs.tar.xz        → 404
    //   media.githubusercontent.com/media/...（LFS 端点）           → 404
    // 仓库里只剩 rootfs.tar.xz.sha256（值也和上面对不上了）。
    //
    // 没有替换成 LXC 镜像那类源，是因为它们的路径带每日日期，
    // 而这个目录的前提是「URL 和校验和都能写死」—— 一个会变的 URL
    // 没法固定校验和，等于把「下一坨东西然后在里面执行代码」这件事
    // 交给运气。
    //
    // 标成不可用而不是删掉：用户问「怎么没有 Debian」时应该看得到原因。
    // Ubuntu 24.04 同样是 glibc + apt，覆盖同一个需求。
    blockedReason: '上游 docker-debian-artifacts 已不再提供 rootfs.tar.xz '
        '（改为 OCI 布局），目前没有可固定 URL + 校验和的下载点。'
        '需要 glibc + apt 请选 Ubuntu 24.04',
  );

  static const ubuntu = Distro(
    id: 'ubuntu-24.04',
    displayName: 'Ubuntu 24.04 LTS',
    description: '30MB 下载 / 130MB 解开。glibc，包管理器 apt。'
        'PPA 和大量第三方安装脚本默认假设的环境。',
    rootfsUrls: {
      'arm64-v8a':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
      'x86_64':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz',
    },
    sources: [
      DistroSource(
          id: 'ubuntu-ustc',
          displayName: '中科大 USTC',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
            'x86_64':
                'https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.ustc.edu.cn/ubuntu'),
      DistroSource(
          id: 'ubuntu-nju',
          displayName: '南京大学 NJU',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.nju.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
            'x86_64':
                'https://mirrors.nju.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.nju.edu.cn/ubuntu'),
      // 同 Alpine：TUNA 的 ubuntu-cdimage 在本机实测 403，不再当默认。
      DistroSource(
          id: 'ubuntu-tuna',
          displayName: '清华 TUNA',
          region: MirrorRegion.china,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
            'x86_64':
                'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu'),
      DistroSource(
          id: 'ubuntu-official',
          displayName: 'Canonical 官方',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
            'x86_64':
                'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz'
          },
          packageBaseUrl: 'https://ports.ubuntu.com/ubuntu-ports'),
      DistroSource(
          id: 'ubuntu-mit',
          displayName: 'MIT',
          region: MirrorRegion.international,
          rootfsUrls: {
            'arm64-v8a':
                'https://mirrors.mit.edu/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz',
            'x86_64':
                'https://mirrors.mit.edu/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-amd64.tar.gz'
          },
          packageBaseUrl: 'https://mirrors.mit.edu/ubuntu'),
    ],
    // 取自 cdimage 的 SHA256SUMS。**版本号是路径的一部分**，
    // Ubuntu 会在同一个 24.04 目录下不断发新的点版本（.3 / .4 …），
    // 老的会被清掉 —— 所以升级点版本时 URL 和校验和必须一起改。
    sha256: {
      'arm64-v8a':
          '04207713ece899c3740823d33690441ad3a7f0ded1101aca744e2b0f37ac7ff2',
      'x86_64':
          'c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58',
    },
    approxInstalledBytes: 130 * 1024 * 1024,
    packageManager: 'apt',
  );

  static const all = [alpine, debian, ubuntu];

  static const defaultDistro = alpine;

  static Distro? byId(String id) {
    for (final d in all) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 当前设备能装哪些（含被标记为不可用的，UI 需要把它们灰掉展示，
  /// 而不是悄悄隐藏 —— 用户问「怎么没有 Debian」时应该看得到原因）。
  static List<Distro> forAbi(String abi) =>
      all.where((d) => d.supports(abi)).toList();

  /// 真正可以装的。
  static List<Distro> installableFor(String abi) =>
      all.where((d) => d.supports(abi) && d.isAvailableOn(abi)).toList();
}

/// 安装进度。
class DistroProgress {
  final String stage;

  /// 0..1；-1 表示不确定（tar 没有条目总数，只能按字节估）。
  final double fraction;

  const DistroProgress(this.stage, [this.fraction = -1]);
}

class DistroInstallException implements Exception {
  final String message;
  const DistroInstallException(this.message);
  @override
  String toString() => message;
}

/// 已安装的发行版。
class InstalledDistro {
  final Distro distro;
  final Directory rootfs;
  const InstalledDistro(this.distro, this.rootfs);
}

class DistroManager {
  /// 所有发行版的父目录。
  final Directory root;

  /// 当前设备 ABI（`Platform.version` 拿不到，由原生侧提供）。
  final String abi;

  /// 注入 HTTP 下载。抽出来是为了单测能塞一个本地文件流进去，
  /// 不必真的去 CDN 拉 30MB。
  final Future<Stream<List<int>>> Function(String url) fetch;

  DistroManager({
    required this.root,
    required this.abi,
    required this.fetch,
  });

  Directory rootfsDirFor(Distro d) => Directory('${root.path}/${d.id}/rootfs');
  File _stampFor(Distro d) => File('${root.path}/${d.id}/.installed');
  Directory _stagingFor(Distro d) => Directory('${root.path}/${d.id}/staging');

  /// 装好没有。
  ///
  /// 看哨兵文件而不是看目录存在：解压到一半被杀会留下一个存在但残缺的
  /// rootfs，那种环境跑起来的报错完全没法定位，必须当成没装。
  Future<bool> isInstalled(Distro d) => _stampFor(d).exists();

  Future<List<InstalledDistro>> listInstalled() async {
    final out = <InstalledDistro>[];
    for (final d in DistroCatalog.all) {
      if (await isInstalled(d)) out.add(InstalledDistro(d, rootfsDirFor(d)));
    }
    return out;
  }

  /// 下载并解压一个发行版。
  ///
  /// 全程在 staging 目录里做，最后**原子 rename** 成 rootfs ——
  /// 和 PrefixGenerations 用的是同一招（也是 TermuxInstaller 的原始手法）：
  /// 中途失败等于什么都没发生，绝不留下半个环境。
  Stream<DistroProgress> install(Distro d, {DistroSource? source}) async* {
    if (!d.supports(abi)) {
      throw DistroInstallException('${d.displayName} 没有 $abi 的 rootfs');
    }

    final blocked = d.blockedReasonFor(abi);
    if (blocked != null) {
      throw DistroInstallException('${d.displayName} 暂不可用：$blocked');
    }
    final chosenSource = source ?? (d.sources.isEmpty ? null : d.sources.first);
    final url = chosenSource?.rootfsUrls[abi] ?? d.rootfsUrls[abi]!;

    final staging = _stagingFor(d);
    final rootfs = rootfsDirFor(d);

    // 上次崩在中途的残留。它一定是不完整的。
    if (await staging.exists()) await staging.delete(recursive: true);
    if (await rootfs.exists() && !await isInstalled(d)) {
      await rootfs.delete(recursive: true);
    }
    await staging.create(recursive: true);
    _verifiedDirs.clear();

    yield DistroProgress('下载 ${d.displayName}', 0);

    // 先整包落盘再解压，而不是边下边解：
    // 校验和要对**完整文件**算，边下边解就没法在执行任何东西之前验证它。
    final isXz = url.endsWith('.xz');
    final archive =
        File('${staging.path}/.rootfs.${isXz ? 'tar.xz' : 'tar.gz'}');
    final sink = archive.openWrite();
    var downloaded = 0;
    try {
      await for (final chunk in await fetch(url)) {
        sink.add(chunk);
        downloaded += chunk.length;
        yield DistroProgress('下载 ${d.displayName}（${_mb(downloaded)}）', -1);
      }
    } finally {
      await sink.close();
    }

    yield const DistroProgress('校验完整性', -1);
    final expected = d.sha256[abi];
    final actual = await _sha256OfFile(archive);
    if (expected == null || expected.isEmpty) {
      // 目录里还没填校验和。这是开发期状态，不能静默放过 ——
      // 但也不该直接失败，否则加新发行版时无从取得那个值。
      // 打印出来让人填回 DistroCatalog。
      // ignore: avoid_print
      print('burrow: 【警告】${d.id}/$abi 没有校验和，实测值 = $actual');
    } else if (actual != expected) {
      await staging.delete(recursive: true);
      throw DistroInstallException(
          '${d.displayName} 校验失败：期望 $expected，实际 $actual。'
          '下载可能被篡改或损坏，已丢弃。');
    }

    yield const DistroProgress('解压 rootfs', 0);

    final target = Directory('${staging.path}/rootfs');
    await target.create(recursive: true);

    // 越界检查的两个基准。必须在写第一个条目之前算好。
    // _rootReal 只能在目录**已经存在**之后才解析得出来，所以放在 create 之后。
    _rootLexical = target.absolute.path;
    _rootReal = await target.resolveSymbolicLinks();
    final totalBytes = await archive.length();
    final skipped = <String>[];
    var files = 0;

    // 进度只能靠已读的压缩字节估 —— tar 没有条目总数（见 TarReader 注释）。
    var lastYield = 0;
    final progressEvents = <DistroProgress>[];

    File tarInput = archive;
    if (isXz) {
      yield const DistroProgress('解码 XZ', -1);
      tarInput = File('${staging.path}/.rootfs.tar');
      final input = InputFileStream(archive.path);
      final output = OutputFileStream(tarInput.path);
      XZDecoder().decodeStream(input, output);
      await input.close();
      await output.close();
    }

    await TarReader.extract(
      tarInput.openRead(),
      gzipCompressed: !isXz,
      onEntry: (entry, content) =>
          _writeEntry(target, entry, content).then((_) => files++),
      onSkipped: (entry, reason) => skipped.add(entry.name),
      onProgress: (read) {
        // gzip 解出来的字节数会大于压缩包大小，所以这个比例只是个估计，
        // 超过 1 就夹住。宁可进度条走得快些也不要停在 90% 不动。
        if (read - lastYield < 2 * 1024 * 1024) return;
        lastYield = read;
        progressEvents.add(DistroProgress('解压 rootfs（$files 个文件）',
            (read / (totalBytes * 3)).clamp(0.0, 0.99)));
      },
    );

    for (final p in progressEvents) {
      yield p;
    }

    yield const DistroProgress('配置环境', 0.99);
    await _postInstall(target, d, chosenSource);
    await archive.delete();
    if (isXz && await tarInput.exists()) await tarInput.delete();

    // 原子切换。到这一步之前失败，用户的已有环境毫发无损。
    if (await rootfs.exists()) await rootfs.delete(recursive: true);
    await rootfs.parent.create(recursive: true);
    await target.rename(rootfs.path);
    await staging.delete(recursive: true);

    await _stampFor(d).writeAsString(jsonEncode({
      'id': d.id,
      'abi': abi,
      'files': files,
      'skipped': skipped.length,
      'installed_at': DateTime.now().toIso8601String(),
      'source': chosenSource?.id,
    }));

    yield DistroProgress(
        '完成（$files 个文件'
        '${skipped.isEmpty ? '' : '，跳过 ${skipped.length} 个设备节点'}）',
        1);
  }

  Future<void> remove(Distro d) async {
    final dir = Directory('${root.path}/${d.id}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  // ---------------------------------------------------------------------

  /// 已确认「真实路径仍在 root 内」的父目录。
  ///
  /// 每个文件都 resolveSymbolicLinks 一次太慢（Ubuntu base 有 2500+ 个文件），
  /// 而同一个目录下往往有几十上百个文件，缓存能把这个开销摊掉。
  final Set<String> _verifiedDirs = {};

  /// rootfs 的**字面**路径和**软链解析后**的路径。
  ///
  /// 两个都要存，因为 Android 上这俩不一样：`getApplicationSupportDirectory()`
  /// 给的是 `/data/user/0/<pkg>/…`，而 `/data/user/0` 本身是指向 `/data/data`
  /// 的软链，所以 `resolveSymbolicLinks()` 会返回 `/data/data/<pkg>/…`。
  ///
  /// 拿「已解析的子路径」去比「未解析的根」是范畴错误 —— 前缀天然对不上，
  /// 于是 rootfs 里第一个条目就会被误判成恶意归档。
  String _rootLexical = '';
  String _rootReal = '';

  /// 判断 [child] 是否在 [root] 之内。
  ///
  /// 交给 `package:path` 而不是手写前缀比较。手写要同时对付三件事：
  ///   - 分隔符（Android 是 `/`，跑单测的 Windows 是 `\`）
  ///   - 边界（裸 `startsWith` 会让 `/a/rootfs-evil` 通过 `/a/rootfs` 的检查）
  ///   - `.` / `..` 归一化
  /// 每一条写漏了都是一个静默的安全洞或者误报，没必要自己重来一遍。
  static bool _isInside(String child, String root) {
    if (root.isEmpty) return true;
    return p.equals(child, root) || p.isWithin(root, child);
  }

  Future<void> _writeEntry(
      Directory target, TarEntry entry, Uint8List? content) async {
    final full = File('${target.path}/${entry.name}').absolute.path;

    // ---- 第一道：字面路径检查 ----
    // 挡 `../../../etc/passwd` 这种（zip slip 的 tar 版本）。
    if (!_isInside(full, _rootLexical)) {
      throw DistroInstallException('rootfs 里有越界路径 ${entry.name}，拒绝解压（可能是恶意归档）');
    }

    // ---- 第二道：软链穿透检查 ----
    //
    // 字面检查挡不住这个：归档里先放一个 `bin -> /etc` 的软链，再放一个
    // `bin/passwd` 的普通文件 —— 后者的字面路径完全在 root 内，但写下去
    // 会**穿透软链**落到 /etc/passwd。
    //
    // 这不是假想的攻击面：Ubuntu 的 rootfs 本身就带 `bin -> usr/bin`
    // （usr-merge），软链目录在真实归档里是常态，所以「见到软链目录就拒绝」
    // 这种粗暴做法不可行。只能逐个确认父目录**解析之后**仍在 root 内。
    final parent = File(full).parent;
    if (!_verifiedDirs.contains(parent.path)) {
      await parent.create(recursive: true);
      try {
        // 和 _rootReal 比，不是和 _rootLexical 比 —— 两边都必须是解析后的路径。
        final resolved = await parent.resolveSymbolicLinks();
        if (!_isInside(resolved, _rootReal)) {
          throw DistroInstallException('${entry.name} 的父目录经软链解析后落在 rootfs 之外'
              '（$resolved 不在 $_rootReal 内），拒绝解压（可能是恶意归档）');
        }
      } on FileSystemException {
        // 解析不了：父目录链上有悬空软链（目标还没解压出来）。
        // rootfs 里这很常见，不能因此中止。此时退回第一道的字面检查 ——
        // 它上面已经过了，所以这里放行，真正的失败留给后面的写入去暴露。
      }
      _verifiedDirs.add(parent.path);
    }

    switch (entry.type) {
      case TarEntryType.directory:
        await Directory(full).create(recursive: true);
        await _chmod(full, entry.mode);

      case TarEntryType.regular:
        final f = File(full);
        await f.writeAsBytes(content ?? Uint8List(0), flush: false);
        await _chmod(full, entry.mode);

      case TarEntryType.symlink:
        final link = Link(full);
        // rootfs 里有大量指向绝对路径的软链（/bin/sh -> /bin/busybox）。
        // **不要**把它们改写成宿主的绝对路径 —— 它们要在 proot 的
        // rootfs 视角下解析才对，原样保留才是正确的。
        if (await link.exists()) await link.delete();
        await link.create(entry.linkTarget, recursive: true);

      case TarEntryType.hardlink:
        // busybox 的几百个命令全是指向同一个 inode 的硬链接。
        // Dart 没有硬链接 API，交给 ln；失败就退回复制 ——
        // 多占点空间，但命令还在。
        final src = '${target.path}/${entry.linkTarget}';
        final r = await Process.run('ln', [src, full]);
        if (r.exitCode != 0) {
          final srcFile = File(src);
          if (await srcFile.exists()) await srcFile.copy(full);
        }

      case TarEntryType.unsupported:
        break; // 已在 TarReader 里报告过
    }
  }

  static Future<void> _chmod(String path, int mode) async {
    if (Platform.isWindows) return;
    if (mode == 0) return;
    // Dart 没有 chmod。这是解压路径上的热点（几千次调用），
    // 每次 fork 一个 chmod 进程会非常慢 —— 所以只对**需要执行位**的
    // 文件真正调用，其余的用默认权限就够了。
    if (mode & 0x49 == 0) return; // 没有任何 x 位
    await Process.run('chmod', [mode.toRadixString(8).padLeft(3, '0'), path]);
  }

  /// 解压之后必须补的东西。缺任何一样，rootfs 起来都是残的。
  Future<void> _postInstall(
      Directory rootfs, Distro d, DistroSource? source) async {
    // DNS。rootfs 里的 resolv.conf 要么不存在要么指向宿主拿不到的地址，
    // 不写这个的话 apk/apt 全部「暂时不能解析域名」。
    final resolv = File('${rootfs.path}/etc/resolv.conf');
    await resolv.parent.create(recursive: true);
    await resolv.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // hosts。很多脚本假设 localhost 能解析。
    final hosts = File('${rootfs.path}/etc/hosts');
    if (!await hosts.exists()) {
      await hosts.writeAsString('127.0.0.1 localhost\n::1 localhost\n');
    }

    // proot 下 /proc/self/exe 等路径的行为和真机不同，一些工具会因此
    // 误判自己的安装位置。给个环境标记让脚本（和 LLM）能识别处境。
    final profile = File('${rootfs.path}/etc/profile.d/burrow.sh');
    await profile.parent.create(recursive: true);
    await profile.writeAsString(
      '# Burrow 沙箱环境标记\n'
      'export PA_DISTRO=${d.id}\n'
      'export BURROW_IN_SANDBOX=1\n'
      'export DEBIAN_FRONTEND=noninteractive\n'
      'export LANG=C.UTF-8\n',
    );

    // Alpine 的 minirootfs 不带软件源列表，apk 直接不可用。
    if (d.packageManager == 'apk') {
      final repos = File('${rootfs.path}/etc/apk/repositories');
      await repos.parent.create(recursive: true);
      if (!await repos.exists() ||
          (await repos.readAsString()).trim().isEmpty) {
        final ver = d.id.split('-').last;
        final base =
            source?.packageBaseUrl ?? 'https://dl-cdn.alpinelinux.org/alpine';
        await repos.writeAsString(
          '$base/v$ver/main\n'
          '$base/v$ver/community\n',
        );
      }
    }

    if (d.packageManager == 'apt' && source != null) {
      final sources = File('${rootfs.path}/etc/apt/sources.list');
      await sources.parent.create(recursive: true);
      final isDebian = d.id.startsWith('debian');
      final suite = isDebian ? 'bookworm' : 'noble';
      final packageBase =
          !isDebian && source.id == 'ubuntu-official' && abi == 'x86_64'
              ? 'https://archive.ubuntu.com/ubuntu'
              : source.packageBaseUrl;
      final components = isDebian
          ? 'main contrib non-free non-free-firmware'
          : 'main restricted universe multiverse';
      final debianSecurity = source.packageBaseUrl.contains('tuna.tsinghua')
          ? 'https://mirrors.tuna.tsinghua.edu.cn/debian-security'
          : 'https://security.debian.org/debian-security';
      await sources.writeAsString(isDebian
          ? 'deb $packageBase $suite $components\n'
              'deb $packageBase $suite-updates $components\n'
              'deb $debianSecurity $suite-security $components\n'
          : 'deb $packageBase $suite $components\n'
              'deb $packageBase $suite-updates $components\n'
              'deb $packageBase $suite-security $components\n');
    }

    // 临时目录。很多包管理器会直接假设它存在且可写。
    await Directory('${rootfs.path}/tmp').create(recursive: true);
    await _chmod('${rootfs.path}/tmp', 0x1FF); // 777
    // proot 会 bind 进来，但目录得先存在
    for (final d in ['proc', 'sys', 'dev', 'workspace']) {
      await Directory('${rootfs.path}/$d').create(recursive: true);
    }
  }

  static Future<String> _sha256OfFile(File f) async {
    // 分块喂给 hasher，不整包进内存 —— 这里的文件可能有 130MB。
    final sink = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in f.openRead()) {
      input.add(chunk);
    }
    input.close();
    return sink.events.single.toString();
  }

  static String _mb(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
