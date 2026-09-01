/// Skills：把一份写好的操作手册接给模型。
///
/// ## 这是什么
///
/// 一个 skill 就是一个目录，里面有一个 `SKILL.md`，开头是 YAML frontmatter：
///
/// ```
/// ---
/// name: pdf-processing
/// description: 从 PDF 里抽取文本、拆分合并页面。处理 PDF 时使用。
/// ---
///
/// (正文：具体怎么做，可以带脚本和示例)
/// ```
///
/// 目录可以再带脚本和资源文件，模型在沙箱里直接调用它们。
/// 数据模型对齐 cc-switch 的 `services/skill.rs`：仓库来源是
/// `owner/name@branch`，skill 的唯一键是 `owner/name:directory`。
///
/// ## 为什么是「渐进式披露」而不是全塞进提示词
///
/// 一份 SKILL.md 动辄几千字。十个 skill 全量塞进系统提示，
/// 上下文就没了 —— 而绝大多数对话一个 skill 都用不上。
///
/// 所以只把 **name + description**（两行）放进系统提示，正文留在磁盘上，
/// 模型判断需要时用 `read_skill` 工具读全文。这也是 Claude 的做法：
/// description 是唯一常驻的部分，所以它必须写清楚「什么时候该用我」，
/// 而不只是「我是什么」。
///
/// ## 装到哪
///
/// 装进 rootfs 的 `/opt/burrow-skills/<directory>`，而不是 workspace：
///   - workspace 会被检查点回滚。skill 是环境的一部分，不该跟着任务的
///     文件改动一起被撤销。
///   - 放 rootfs 里模型在沙箱内能直接 `bash /opt/burrow-skills/x/run.sh`，
///     不用先复制出来。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../bootstrap/zip_reader.dart';

/// 一个 skill 的元信息。
class Skill {
  /// 唯一键。仓库来的是 `owner/name:directory`，本地导入的是 `local:directory`。
  final String key;

  final String name;
  final String description;

  /// 安装后的目录名，也是 rootfs 里的路径最后一段。
  final String directory;

  final String? repoOwner;
  final String? repoName;
  final String? repoBranch;

  /// 已安装的才有值：SKILL.md 在宿主文件系统上的绝对路径。
  final String? skillFilePath;

  /// 用户有没有把它打开。装了但关着的不会进系统提示 ——
  /// 装十个全开着，那两行摘要也会堆成几百 token。
  final bool enabled;

  const Skill({
    required this.key,
    required this.name,
    required this.description,
    required this.directory,
    this.repoOwner,
    this.repoName,
    this.repoBranch,
    this.skillFilePath,
    this.enabled = false,
  });

  bool get installed => skillFilePath != null;

  Skill copyWith({
    String? skillFilePath,
    bool? enabled,
    String? name,
    String? description,
  }) =>
      Skill(
        key: key,
        name: name ?? this.name,
        description: description ?? this.description,
        directory: directory,
        repoOwner: repoOwner,
        repoName: repoName,
        repoBranch: repoBranch,
        skillFilePath: skillFilePath ?? this.skillFilePath,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
        'key': key,
        'name': name,
        'description': description,
        'directory': directory,
        'repo_owner': repoOwner,
        'repo_name': repoName,
        'repo_branch': repoBranch,
        'enabled': enabled,
      };

  static Skill fromJson(Map<String, Object?> j) => Skill(
        key: j['key']! as String,
        name: j['name']! as String,
        description: j['description'] as String? ?? '',
        directory: j['directory']! as String,
        repoOwner: j['repo_owner'] as String?,
        repoName: j['repo_name'] as String?,
        repoBranch: j['repo_branch'] as String?,
        enabled: j['enabled'] as bool? ?? false,
      );
}

/// 一个 skill 仓库来源。
class SkillRepo {
  final String owner;
  final String name;
  final String branch;

  const SkillRepo({
    required this.owner,
    required this.name,
    this.branch = 'main',
  });

  String get slug => '$owner/$name';

  /// GitHub 的 zipball 地址。用 codeload 而不是 API 的 `/zipball`：
  /// 后者会 302 到前者，而 Dart 的 http 客户端跟随重定向时会把
  /// Authorization 头一起带过去，那是不必要的凭据外泄面。
  String get archiveUrl =>
      'https://codeload.github.com/$owner/$name/zip/refs/heads/$branch';

  Map<String, Object?> toJson() =>
      {'owner': owner, 'name': name, 'branch': branch};

  static SkillRepo fromJson(Map<String, Object?> j) => SkillRepo(
        owner: j['owner']! as String,
        name: j['name']! as String,
        branch: j['branch'] as String? ?? 'main',
      );

  /// 从 `owner/name`、`owner/name@branch` 或 GitHub 网址解析。
  ///
  /// 接受网址是因为用户手上拿到的多半就是一条 github.com 链接，
  /// 让他们自己拆成两段再填是没必要的摩擦。
  static SkillRepo? parse(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;

    var branch = 'main';
    final uri = Uri.tryParse(text);
    if (uri != null &&
        (uri.host == 'github.com' || uri.host.endsWith('.github.com'))) {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < 2) return null;
      // .../tree/<branch>/... 形式里带了分支
      final treeIndex = segments.indexOf('tree');
      if (treeIndex >= 0 && treeIndex + 1 < segments.length) {
        branch = segments[treeIndex + 1];
      }
      return SkillRepo(
        owner: segments[0],
        name: segments[1].replaceAll(RegExp(r'\.git$'), ''),
        branch: branch,
      );
    }

    final at = text.lastIndexOf('@');
    if (at > 0) {
      branch = text.substring(at + 1).trim();
      text = text.substring(0, at).trim();
      if (branch.isEmpty) branch = 'main';
    }
    final parts = text.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length != 2) return null;
    return SkillRepo(owner: parts[0], name: parts[1], branch: branch);
  }
}

class SkillException implements Exception {
  final String message;
  const SkillException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// SKILL.md 解析
// ---------------------------------------------------------------------------

/// SKILL.md 头部 frontmatter 里的 name / description。
///
/// 手写一个极小的解析器而不是引 yaml 包：这里只需要顶层的两个标量键，
/// 而一个完整的 YAML 解析器意味着要处理锚点、别名、多文档 —— 那些东西
/// 出现在 skill 头部只会是攻击面，不会是功能。
///
/// **但块标量必须支持。** anthropics/skills 里就有一批 skill 这么写：
///
/// ```yaml
/// description: >
///   第一行
///   第二行
/// ```
///
/// 只取冒号后面那一截的话，description 会变成一个字面的 `>` 或 `|-`，
/// 而那正是要放进系统提示、决定模型用不用这个 skill 的那句话 ——
/// 实测在真仓库上踩到过，列表里直接显示成一个 `>`。
class SkillFrontmatter {
  final String? name;
  final String? description;
  const SkillFrontmatter({this.name, this.description});

  static SkillFrontmatter parse(String markdown) {
    final lines = const LineSplitter().convert(markdown);
    if (lines.isEmpty || lines.first.trim() != '---') {
      return const SkillFrontmatter();
    }
    String? name;
    String? description;

    var i = 1;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim() == '---') break;
      i++;

      // 只认顶层键。缩进了的是嵌套结构或者上一个块标量的续行，
      // 在这里跳过它可以避免把 `metadata:` 下面的 name 当成 skill 名。
      if (line.startsWith(' ') || line.startsWith('\t')) continue;

      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      if (key != 'name' && key != 'description') continue;

      var value = line.substring(colon + 1).trim();

      // 块标量：`>` 折叠、`|` 保留换行，后面可以跟 `-` / `+` / 缩进数字。
      // 真正的内容在后面那些缩进行里。
      if (value.isNotEmpty && (value[0] == '>' || value[0] == '|')) {
        final folded = value[0] == '>';
        final collected = <String>[];
        while (i < lines.length) {
          final next = lines[i];
          if (next.trim() == '---') break;
          // 空行属于块的一部分（折叠模式下代表分段）；
          // 非空且不缩进的行说明块结束了，把它留给外层循环处理。
          if (next.trim().isNotEmpty &&
              !next.startsWith(' ') &&
              !next.startsWith('\t')) {
            break;
          }
          collected.add(next.trim());
          i++;
        }
        // 折叠模式下换行变空格；保留模式下保留换行。
        // 末尾的空行一律去掉 —— `>-` / `|-` 的语义就是不保留结尾换行，
        // 而带 `+` 的情况在 skill 头部没有意义。
        while (collected.isNotEmpty && collected.last.isEmpty) {
          collected.removeLast();
        }
        value = folded ? collected.join(' ').trim() : collected.join('\n');
      } else if (value.length >= 2) {
        final first = value[0];
        if ((first == '"' || first == "'") && value.endsWith(first)) {
          value = value.substring(1, value.length - 1);
        }
      }

      if (value.isEmpty) continue;
      if (key == 'name') name = value;
      if (key == 'description') description = value;
    }
    return SkillFrontmatter(name: name, description: description);
  }
}

// ---------------------------------------------------------------------------
// 存储
// ---------------------------------------------------------------------------

/// 已连接的仓库、已安装的 skill，以及它们在磁盘上的落点。
class SkillStore {
  /// 宿主上的 skills 根目录（rootfs 内的 `/opt/burrow-skills`）。
  ///
  /// 没装发行版时为 null —— 那种情况下 skill 装了也没地方跑，
  /// UI 应该明确说出来而不是装完了发现用不了。
  ///
  /// 可变：用户可以在聊天里当场装基座（见 SandboxSession.attachDistro）。
  /// 改它的唯一入口是 [rebindRoot]，因为换目录必须重新核对哪些还装着。
  Directory? root;

  /// 索引文件。放在 app 的私有目录而不是 rootfs 里：
  /// rootfs 会被「代目录 + 原子 rename」整个换掉，索引跟着丢了
  /// 用户就会看到"我明明装过的 skill 不见了"。
  final File indexFile;

  /// 注入下载。抽出来是为了单测能塞一个本地 zip 进去。
  final Future<List<int>> Function(String url) fetch;

  final List<SkillRepo> _repos = [];
  final Map<String, Skill> _skills = {};

  SkillStore({
    required this.root,
    required this.indexFile,
    required this.fetch,
  });

  List<SkillRepo> get repos => List.unmodifiable(_repos);

  List<Skill> get skills =>
      _skills.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  List<Skill> get enabled =>
      skills.where((s) => s.enabled && s.installed).toList();

  bool get ready => root != null;

  Future<void> open() async {
    if (!await indexFile.exists()) return;
    try {
      final json = jsonDecode(await indexFile.readAsString());
      if (json is! Map<String, Object?>) return;
      _repos
        ..clear()
        ..addAll((json['repos'] as List? ?? const [])
            .whereType<Map<String, Object?>>()
            .map(SkillRepo.fromJson));
      _skills.clear();
      for (final raw in (json['skills'] as List? ?? const [])
          .whereType<Map<String, Object?>>()) {
        final skill = Skill.fromJson(raw);
        // 索引说装了，但目录可能已经被"代目录回滚"带走了。
        // 以磁盘为准 —— 索引里写着装了而实际没有，模型会读到一个
        // 不存在的文件然后卡住。
        final path = _skillFilePathFor(skill.directory);
        final exists = path != null && await File(path).exists();
        _skills[skill.key] =
            exists ? skill.copyWith(skillFilePath: path) : skill;
      }
    } catch (e) {
      // 索引坏了不该让 app 起不来。清空重来，代价是用户要重装 skill，
      // 而那比"打不开 app"好得多。
      _repos.clear();
      _skills.clear();
    }
  }

  Future<void> _save() async {
    await indexFile.parent.create(recursive: true);
    await indexFile.writeAsString(jsonEncode({
      'repos': _repos.map((r) => r.toJson()).toList(),
      'skills': _skills.values.map((s) => s.toJson()).toList(),
    }));
  }

  String? _skillFilePathFor(String directory) {
    final base = root;
    if (base == null) return null;
    return p.join(base.path, directory, 'SKILL.md');
  }

  /// 换一个 rootfs（用户运行中装好了基座，或者切了发行版）。
  ///
  /// 换完要重新核对每个 skill 在**新** rootfs 里到底还在不在 ——
  /// 索引是跟着 app 走的，而文件是跟着 rootfs 走的，换个发行版
  /// 索引里那些"已安装"就全都指向不存在的路径了。模型会照着一份
  /// 系统提示里列出的 skill 去 read_skill，然后拿到一堆失败。
  Future<void> rebindRoot(Directory? newRoot) async {
    if (newRoot?.path == root?.path) return;
    root = newRoot;
    for (final entry in _skills.entries.toList()) {
      final path = _skillFilePathFor(entry.value.directory);
      final exists = path != null && await File(path).exists();
      _skills[entry.key] = exists
          ? entry.value.copyWith(skillFilePath: path)
          : Skill.fromJson(entry.value.toJson()); // 丢掉 skillFilePath
    }
    await _save();
  }

  Future<void> addRepo(SkillRepo repo) async {
    if (_repos.any((r) => r.slug == repo.slug)) return;
    _repos.add(repo);
    await _save();
  }

  Future<void> removeRepo(SkillRepo repo) async {
    _repos.removeWhere((r) => r.slug == repo.slug);
    // 只摘来源，不卸载已经装好的 skill —— 装好的东西正在被使用，
    // 摘一个来源就把它们一起删掉是用户不会预期的破坏。
    await _save();
  }

  Future<void> setEnabled(String key, bool value) async {
    final skill = _skills[key];
    if (skill == null) return;
    _skills[key] = skill.copyWith(enabled: value);
    await _save();
  }

  Future<void> uninstall(String key) async {
    final skill = _skills.remove(key);
    if (skill != null) {
      final base = root;
      if (base != null) {
        final dir = Directory(p.join(base.path, skill.directory));
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
    await _save();
  }

  /// 拉一个仓库，列出里面所有的 skill。
  ///
  /// 整包下载再在内存里读，而不是走 GitHub 的目录 API 逐个请求：
  /// 一个有二十个 skill 的仓库那样要四十次请求，未认证的话直接撞限流。
  Future<List<Skill>> discover(SkillRepo repo) async {
    return _withArchive(repo, (zip, entries) async {
      final found = <Skill>[];
      for (final entry in entries) {
        if (!entry.name.endsWith('/SKILL.md')) continue;
        // zipball 的路径都带一层 `<repo>-<branch>/` 前缀，
        // 所以至少三段才可能是「某个子目录下的 SKILL.md」。
        final parts = entry.name.split('/');
        if (parts.length < 3) continue;
        final directory = parts[parts.length - 2];

        final content =
            utf8.decode(await zip.read(entry), allowMalformed: true);
        final meta = SkillFrontmatter.parse(content);
        final key = '${repo.slug}:$directory';
        found.add(Skill(
          key: key,
          // 没写 name 就用目录名。目录名总是有的，而一个没有名字的
          // 条目在列表里等于不可见。
          name: meta.name ?? directory,
          description: meta.description ?? '',
          directory: directory,
          repoOwner: repo.owner,
          repoName: repo.name,
          repoBranch: repo.branch,
          skillFilePath: _skills[key]?.skillFilePath,
          enabled: _skills[key]?.enabled ?? false,
        ));
      }
      found.sort((a, b) => a.name.compareTo(b.name));
      return found;
    });
  }

  /// 下载归档 → 落临时文件 → 交给 ZipReader → 收拾干净。
  ///
  /// ZipReader 是随机读的（走 central directory），需要一个可 seek 的文件，
  /// 所以必须先落盘。临时文件在 finally 里删 —— 抛异常时也不能留下
  /// 几十 MB 的垃圾，手机上那是真的会攒起来。
  Future<T> _withArchive<T>(
    SkillRepo repo,
    Future<T> Function(ZipReader zip, List<ZipEntry> entries) body,
  ) async {
    final bytes = await fetch(repo.archiveUrl);
    final temp = File(p.join(
      indexFile.parent.path,
      '.skill-${repo.owner}-${repo.name}-${DateTime.now().microsecondsSinceEpoch}.zip',
    ));
    await temp.parent.create(recursive: true);
    await temp.writeAsBytes(bytes);

    ZipReader? zip;
    try {
      zip = await ZipReader.open(temp);
      return await body(zip, await zip.entries());
    } finally {
      await zip?.close();
      if (await temp.exists()) await temp.delete();
    }
  }

  /// 把一个 skill 的整个目录装进 rootfs。
  ///
  /// 先解到 `.staging` 再原子 rename，和发行版安装用的是同一招：
  /// 中途失败等于什么都没发生，绝不留下半个 skill —— 半个 skill 的
  /// SKILL.md 可能是完整的而脚本缺了一半，模型会照着手册去调一个
  /// 不存在的脚本，那种失败极难定位。
  Future<Skill> install(Skill skill) async {
    final base = root;
    if (base == null) {
      throw const SkillException('还没有安装发行版基座，skill 装了也没有地方运行');
    }
    if (skill.repoOwner == null || skill.repoName == null) {
      throw const SkillException('这个 skill 没有来源仓库，无法安装');
    }
    final repo = SkillRepo(
      owner: skill.repoOwner!,
      name: skill.repoName!,
      branch: skill.repoBranch ?? 'main',
    );

    final target = Directory(p.join(base.path, skill.directory));
    final staging = Directory('${target.path}.staging');

    final files = await _withArchive(repo, (zip, entries) async {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      // zip 里这个 skill 的路径前缀：`<repo>-<branch>/.../<directory>/`
      String? prefix;
      for (final entry in entries) {
        if (entry.name.endsWith('/${skill.directory}/SKILL.md')) {
          prefix =
              entry.name.substring(0, entry.name.length - 'SKILL.md'.length);
          break;
        }
      }
      if (prefix == null) {
        await staging.delete(recursive: true);
        throw SkillException('仓库里找不到 ${skill.directory}/SKILL.md');
      }

      var count = 0;
      for (final entry in entries) {
        if (!entry.name.startsWith(prefix)) continue;
        final relative = entry.name.substring(prefix.length);
        if (relative.isEmpty || relative.endsWith('/')) continue;

        // 路径逃逸检查。归档内容完全由第三方控制，一个
        // `../../etc/passwd` 条目就能写到 rootfs 里任何地方。
        // 静默跳过而不是中止：一个坏条目不该让整个 skill 装不上，
        // 而放它进去等于把 rootfs 交出去。
        final out = File(p.normalize(p.join(staging.path, relative)));
        if (!p.isWithin(staging.path, out.path)) continue;

        await out.parent.create(recursive: true);
        await out.writeAsBytes(await zip.read(entry));
        count++;
      }
      return count;
    });

    if (files == 0) {
      if (await staging.exists()) await staging.delete(recursive: true);
      throw SkillException('${skill.directory} 里一个文件都没有');
    }

    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);

    final installed = skill.copyWith(
      skillFilePath: p.join(target.path, 'SKILL.md'),
      enabled: true, // 刚装完就打开：装一个东西的意图就是要用它
    );
    _skills[skill.key] = installed;
    await _save();
    return installed;
  }

  /// 读一个已安装 skill 的全文，给 `read_skill` 工具用。
  Future<String?> readSkill(String nameOrKey) async {
    final skill = _skills[nameOrKey] ??
        _skills.values.cast<Skill?>().firstWhere(
              (s) => s!.name == nameOrKey || s.directory == nameOrKey,
              orElse: () => null,
            );
    final path = skill?.skillFilePath;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// 给系统提示用的清单。**只有名字和描述** —— 见文件头关于渐进式披露的说明。
  String promptSection() {
    final list = enabled;
    if (list.isEmpty) return '';
    final b = StringBuffer();
    b.writeln('你有以下 skill 可用。它们是写好的操作手册，'
        '判断哪个和当前任务相关时，用 read_skill 读它的全文再照着做：');
    for (final skill in list) {
      b.writeln('- ${skill.name}：${skill.description}');
    }
    return b.toString();
  }
}
