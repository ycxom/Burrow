/*
 * burrow-launch —— 沙箱启动器。
 *
 * 装好 seccomp filter / landlock ruleset / rlimit，然后 execve 目标命令。
 * 编译成一个独立的小可执行文件，装到 $PREFIX/libexec/burrow-launch。
 *
 *     burrow-launch [--seccomp-no-net] [--landlock-ro=PATH]... [--landlock-rw=PATH]...
 *               [--rlimit-nproc=N] [--rlimit-fsize=N] [--rlimit-as=N] [--rlimit-cpu=N]
 *               -- <command> [args...]
 *
 * ## 为什么必须是独立进程，不能在 JVM 里装
 *
 * seccomp filter 会被子进程继承，但**也会留在当前线程上**。在 app 的 JVM
 * 线程里装一个禁网 filter，会顺带把 Flutter 自己的 HTTP（也就是调 LLM API）
 * 一起禁掉。所以必须 fork 出来、在子进程里装、然后 exec。
 *
 * ## 为什么在 proot 外面
 *
 * seccomp filter 沿 fork/exec 继承，装在最外层才能覆盖 proot 拉起的整棵树。
 * 反过来（proot 里面再 burrow-launch）只能约束到最内层那一个进程。
 *
 * ## Android 上的可用性
 *
 * - seccomp: Android O (API 26) 起 CTS 强制要求，可以直接用。
 * - landlock: 内核 5.13+ 才有，且要 CONFIG_SECURITY_LANDLOCK=y。
 *   GKI 5.15 / 6.1 上部分厂商开了。**必须运行时探测**，不能编译期假设。
 * - user namespace: 多数厂商内核关了，所以 bwrap 那条路走不通 —— 见 SANDBOX.md。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SECCOMP_SET_MODE_FILTER
#define SECCOMP_SET_MODE_FILTER 1
#endif

#if defined(__aarch64__)
#  define PA_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#  define PA_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__x86_64__)
#  define PA_AUDIT_ARCH AUDIT_ARCH_X86_64
#else
#  define PA_AUDIT_ARCH 0
#endif

/* ------------------------------------------------------------------ */
/* seccomp: 禁掉 AF_INET / AF_INET6 的 socket()                         */
/* ------------------------------------------------------------------ */

/*
 * 只拦 socket 的 domain 参数，而不是整个 socket 系统调用 ——
 * AF_UNIX 必须放行，否则 X11、dbus、以及 Android 自己的一堆东西全废，
 * 表现为程序莫名其妙起不来而不是「网络不通」，极难排查。
 *
 * 返回 EPERM 而不是 KILL：让程序自己报「网络不可用」并优雅退出，
 * 比直接被杀掉更容易让 LLM 理解发生了什么。
 * （SandboxSession._scanDenials 会把这类 errno 识别出来告诉模型
 *   「这是沙箱拦的，不是网络故障」。）
 */
static int install_no_net_filter(void) {
    if (PA_AUDIT_ARCH == 0) {
        fprintf(stderr, "burrow-launch: unsupported arch for seccomp\n");
        return -1;
    }

    struct sock_filter filter[] = {
        /* 架构必须匹配，否则 32/64 位混用时 syscall 号对不上，
           filter 会拦错东西。不匹配直接 KILL —— 这是安全关键路径。*/
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, PA_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),

        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),

        /* socket(domain, ...) */
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 0, 5),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 2 /*AF_INET*/, 2, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 10 /*AF_INET6*/, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),

        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };

    struct sock_fprog prog = {
        .len = (unsigned short) (sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };

    /* seccomp 的前提。它同时也会让 setuid 二进制失去提权能力 ——
       在我们这儿是额外收益，不是副作用。*/
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        perror("burrow-launch: PR_SET_NO_NEW_PRIVS");
        return -1;
    }
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) != 0) {
        /* 老内核没有 seccomp(2)，退回 prctl 接口。*/
        if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0) {
            perror("burrow-launch: seccomp");
            return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* landlock: 机会性的文件系统强制                                       */
/* ------------------------------------------------------------------ */

#ifndef __NR_landlock_create_ruleset
#  if defined(__aarch64__) || defined(__x86_64__) || defined(__arm__)
#    define __NR_landlock_create_ruleset 444
#    define __NR_landlock_add_rule       445
#    define __NR_landlock_restrict_self  446
#  endif
#endif

#define LL_FS_EXECUTE     (1ULL << 0)
#define LL_FS_WRITE_FILE  (1ULL << 1)
#define LL_FS_READ_FILE   (1ULL << 2)
#define LL_FS_READ_DIR    (1ULL << 3)
#define LL_FS_REMOVE_DIR  (1ULL << 4)
#define LL_FS_REMOVE_FILE (1ULL << 5)
#define LL_FS_MAKE_REG    (1ULL << 8)
#define LL_FS_MAKE_DIR    (1ULL << 7)

#define LL_RO (LL_FS_EXECUTE | LL_FS_READ_FILE | LL_FS_READ_DIR)
#define LL_RW (LL_RO | LL_FS_WRITE_FILE | LL_FS_REMOVE_DIR | \
               LL_FS_REMOVE_FILE | LL_FS_MAKE_REG | LL_FS_MAKE_DIR)

struct pa_ruleset_attr { __u64 handled_access_fs; };
struct pa_path_beneath_attr { __u64 allowed_access; __s32 parent_fd; } __attribute__((packed));

/* 探测 ABI 版本。返回 0 = 不支持。这个值会一路传到 UI 上显示，
   用户有权知道自己现在实际被保护到什么程度。*/
int pa_landlock_abi(void) {
#ifdef __NR_landlock_create_ruleset
    long abi = syscall(__NR_landlock_create_ruleset, NULL, 0, 1 /*VERSION*/);
    return abi > 0 ? (int) abi : 0;
#else
    return 0;
#endif
}

#ifdef __NR_landlock_create_ruleset
static int ll_fd = -1;

static int landlock_begin(void) {
    struct pa_ruleset_attr attr = { .handled_access_fs = LL_RW };
    ll_fd = (int) syscall(__NR_landlock_create_ruleset, &attr, sizeof(attr), 0);
    return ll_fd;
}

static int landlock_allow(const char *path, __u64 access) {
    if (ll_fd < 0) return -1;
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return 0;  /* 路径不存在就跳过，不是错误 */
    struct pa_path_beneath_attr pb = { .allowed_access = access, .parent_fd = fd };
    int r = (int) syscall(__NR_landlock_add_rule, ll_fd, 1 /*PATH_BENEATH*/, &pb, 0);
    close(fd);
    return r;
}

static int landlock_commit(void) {
    if (ll_fd < 0) return 0;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    int r = (int) syscall(__NR_landlock_restrict_self, ll_fd, 0);
    close(ll_fd);
    ll_fd = -1;
    return r;
}
#else
static int landlock_begin(void) { return -1; }
static int landlock_allow(const char *p, __u64 a) { (void)p; (void)a; return 0; }
static int landlock_commit(void) { return 0; }
#endif

/* ------------------------------------------------------------------ */

static void set_limit(int what, rlim_t value, const char *name) {
    struct rlimit rl = { .rlim_cur = value, .rlim_max = value };
    if (setrlimit(what, &rl) != 0) {
        /* 不致命：设不上就是少一道保险，不该因此拒绝执行命令。
           但要说出来，否则用户以为限制生效了。*/
        fprintf(stderr, "burrow-launch: setrlimit(%s) failed: %s\n",
                name, strerror(errno));
    }
}

int main(int argc, char **argv) {
    int want_no_net = 0;
    int want_landlock = 0;
    const char *ro_paths[32]; int n_ro = 0;
    const char *rw_paths[32]; int n_rw = 0;

    int i = 1;
    for (; i < argc; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--") == 0) { i++; break; }
        else if (strcmp(a, "--seccomp-no-net") == 0) want_no_net = 1;
        else if (strncmp(a, "--landlock-ro=", 14) == 0) {
            if (n_ro < 32) ro_paths[n_ro++] = a + 14;
            want_landlock = 1;
        }
        else if (strncmp(a, "--landlock-rw=", 14) == 0) {
            if (n_rw < 32) rw_paths[n_rw++] = a + 14;
            want_landlock = 1;
        }
        else if (strncmp(a, "--rlimit-nproc=", 15) == 0)
            set_limit(RLIMIT_NPROC, strtoull(a + 15, NULL, 10), "nproc");
        else if (strncmp(a, "--rlimit-fsize=", 15) == 0)
            set_limit(RLIMIT_FSIZE, strtoull(a + 15, NULL, 10), "fsize");
        else if (strncmp(a, "--rlimit-as=", 12) == 0)
            set_limit(RLIMIT_AS, strtoull(a + 12, NULL, 10), "as");
        else if (strncmp(a, "--rlimit-cpu=", 13) == 0)
            set_limit(RLIMIT_CPU, strtoull(a + 13, NULL, 10), "cpu");
        else if (strcmp(a, "--probe") == 0) {
            /* SandboxCapabilities.probe 走这条路。输出 JSON 给 Dart 解析。*/
            printf("{\"seccomp\":%s,\"landlock_abi\":%d,\"rlimit\":true}\n",
                   PA_AUDIT_ARCH != 0 ? "true" : "false", pa_landlock_abi());
            return 0;
        }
        else {
            fprintf(stderr, "burrow-launch: unknown option %s\n", a);
            return 2;
        }
    }

    if (i >= argc) {
        fprintf(stderr, "usage: burrow-launch [options] -- <command> [args...]\n");
        return 2;
    }

    /* 顺序有讲究：landlock 先于 seccomp。
       两者都需要 NO_NEW_PRIVS，而 landlock_restrict_self 之后再 open()
       就受规则约束了 —— seccomp 的安装不碰文件系统，所以放后面安全；
       反过来的话没问题但没必要冒险。*/
    if (want_landlock && pa_landlock_abi() > 0) {
        if (landlock_begin() >= 0) {
            for (int k = 0; k < n_ro; k++) landlock_allow(ro_paths[k], LL_RO);
            for (int k = 0; k < n_rw; k++) landlock_allow(rw_paths[k], LL_RW);
            /* /dev 和 /proc 必须放行，否则 pty、/dev/null、/proc/self/exe
               全部不可用，几乎任何程序都起不来。*/
            landlock_allow("/dev", LL_RW);
            landlock_allow("/proc", LL_RO);
            if (landlock_commit() != 0) {
                fprintf(stderr, "burrow-launch: landlock_restrict_self failed: %s\n",
                        strerror(errno));
            }
        }
    }

    if (want_no_net && install_no_net_filter() != 0) {
        /* 断网装不上时**拒绝执行**，而不是降级放行。
           用户以为自己在离线沙箱里，实际上没有 —— 这种静默降级
           比明着失败危险得多。*/
        fprintf(stderr, "burrow-launch: refusing to run without network isolation\n");
        return 3;
    }

    execvp(argv[i], &argv[i]);
    fprintf(stderr, "burrow-launch: exec %s: %s\n", argv[i], strerror(errno));
    return 127;
}
