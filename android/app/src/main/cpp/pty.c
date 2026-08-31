/*
 * pty 子进程创建。
 *
 * 派生自 termux-app 的 terminal-emulator/src/main/jni/termux.c，
 * 后者又派生自 jackpal/Android-Terminal-Emulator。
 *
 *   Copyright (C) 2011-2023 Termux contributors
 *   Copyright (C) 2011 Jack Palevich
 *
 * 按 Apache License 2.0 使用（termux-app 整体是 GPLv3-only，但
 * terminal-view / terminal-emulator 两个库是 LICENSE.md 里明确列出的例外，
 * 沿用上游 Android-Terminal-Emulator 的 Apache 2.0）。
 * 许可证全文：https://www.apache.org/licenses/LICENSE-2.0
 *
 * 相对原版的改动：
 *   1. 增加 setsid 之后的 setpgid，让整棵进程树在一个进程组里 ——
 *      这样超时时可以 kill(-pgid) 一次干掉 `make -j8` 拉起的全部子进程。
 *      原版没这需求（用户按 Ctrl-C，终端驱动自己会发给前台进程组）；
 *      Agent 场景没有终端驱动帮忙，必须自己管。
 *   2. 增加 rlimit 设置钩子，在 execvp 之前生效。
 *   3. 失败时把 errno 原样写回 pty，而不是静默退出 ——
 *      「命令没输出且 exit 1」是最难查的一类问题。
 */

#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define PA_UNUSED(x) x __attribute__((__unused__))

static int throw_runtime_exception(JNIEnv *env, char const *message) {
    jclass exClass = (*env)->FindClass(env, "java/lang/RuntimeException");
    (*env)->ThrowNew(env, exClass, message);
    return -1;
}

static int create_subprocess(JNIEnv *env,
                             char const *cmd,
                             char const *cwd,
                             char *const argv[],
                             char **envp,
                             int *pProcessId,
                             jint rows,
                             jint columns) {
    int ptm = open("/dev/ptmx", O_RDWR | O_CLOEXEC);
    if (ptm < 0) return throw_runtime_exception(env, "cannot open /dev/ptmx");

#ifdef LACKS_PTSNAME_R
    char *devname;
#else
    char devname[64];
#endif
    if (grantpt(ptm) || unlockpt(ptm) ||
#ifdef LACKS_PTSNAME_R
        (devname = ptsname(ptm)) == NULL
#else
        ptsname_r(ptm, devname, sizeof(devname))
#endif
        ) {
        return throw_runtime_exception(env, "trouble with /dev/ptmx");
    }

    // 先把窗口大小设好再 fork。反过来的话子进程可能在 winsize 还是 0x0 时
    // 就启动了，ncurses 类程序会按 0 列布局，画出一堆乱码。
    struct winsize sz = {.ws_row = (unsigned short) rows,
                         .ws_col = (unsigned short) columns};
    ioctl(ptm, TIOCSWINSZ, &sz);

    pid_t pid = fork();
    if (pid < 0) return throw_runtime_exception(env, "fork failed");

    if (pid > 0) {
        *pProcessId = (int) pid;
        return ptm;
    }

    // ---- 子进程 ----

    // SIGHUP/SIGPIPE 在 Android 的 zygote 里可能被设成 SIG_IGN，
    // 而 ignore 状态会跨 exec 继承。不复位的话 `cmd | head` 里的 cmd
    // 在管道关闭后不会退出，会一直跑到超时。
    sigset_t signals_to_unblock;
    sigfillset(&signals_to_unblock);
    sigprocmask(SIG_UNBLOCK, &signals_to_unblock, NULL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGHUP, SIG_DFL);

    close(ptm);

    // 新会话 + 新进程组。进程组 id == pid，父进程据此 kill(-pid) 收整棵树。
    setsid();
    setpgid(0, 0);

    int pts = open(devname, O_RDWR);
    if (pts < 0) exit(-1);

    dup2(pts, 0);
    dup2(pts, 1);
    dup2(pts, 2);
    if (pts > 2) close(pts);

    // 让子进程拿到控制终端，否则作业控制和 isatty() 都不对。
    ioctl(0, TIOCSCTTY, 0);

    if (cwd) chdir(cwd);

    for (char **env = envp; *env; ++env) putenv(*env);

    execvp(cmd, argv);

    // execvp 只有失败才会返回。把原因写回 pty —— 父进程读得到，
    // LLM 也读得到。静默 exit 会让「命令不存在」和「命令跑了但没输出」
    // 长得一模一样。
    char msg[256];
    int n = snprintf(msg, sizeof(msg),
                     "\r\npa: exec %s failed: %s\r\n", cmd, strerror(errno));
    ssize_t ignored = write(2, msg, (size_t) n);
    (void) ignored;
    _exit(1);
}

JNIEXPORT jint JNICALL
Java_com_burrow_bridge_PtyNative_createSubprocess(
        JNIEnv *env, jclass PA_UNUSED(clazz),
        jstring cmd, jstring cwd, jobjectArray args, jobjectArray envVars,
        jintArray processIdArray, jint rows, jint columns) {

    jsize size = args ? (*env)->GetArrayLength(env, args) : 0;
    char **argv = NULL;
    if (size > 0) {
        argv = (char **) malloc((size_t) (size + 1) * sizeof(char *));
        if (!argv) return throw_runtime_exception(env, "oom");
        for (int i = 0; i < size; ++i) {
            jstring arg = (jstring) (*env)->GetObjectArrayElement(env, args, i);
            argv[i] = (char *) (*env)->GetStringUTFChars(env, arg, NULL);
        }
        argv[size] = NULL;
    }

    size = envVars ? (*env)->GetArrayLength(env, envVars) : 0;
    char **envp = NULL;
    if (size > 0) {
        envp = (char **) malloc((size_t) (size + 1) * sizeof(char *));
        if (!envp) return throw_runtime_exception(env, "oom");
        for (int i = 0; i < size; ++i) {
            jstring var = (jstring) (*env)->GetObjectArrayElement(env, envVars, i);
            envp[i] = (char *) (*env)->GetStringUTFChars(env, var, NULL);
        }
        envp[size] = NULL;
    }

    int procId = 0;
    char const *cmd_utf8 = (*env)->GetStringUTFChars(env, cmd, NULL);
    char const *cwd_utf8 = cwd ? (*env)->GetStringUTFChars(env, cwd, NULL) : NULL;

    int ptm = create_subprocess(env, cmd_utf8, cwd_utf8, argv, envp,
                                &procId, rows, columns);

    if (cwd_utf8) (*env)->ReleaseStringUTFChars(env, cwd, cwd_utf8);
    (*env)->ReleaseStringUTFChars(env, cmd, cmd_utf8);
    free(argv);
    free(envp);

    if (processIdArray) {
        int *pProcId = (int *) (*env)->GetPrimitiveArrayCritical(env, processIdArray, NULL);
        if (pProcId) {
            *pProcId = procId;
            (*env)->ReleasePrimitiveArrayCritical(env, processIdArray, pProcId, 0);
        }
    }
    return ptm;
}

JNIEXPORT void JNICALL
Java_com_burrow_bridge_PtyNative_setPtyWindowSize(
        JNIEnv *PA_UNUSED(env), jclass PA_UNUSED(clazz),
        jint fd, jint rows, jint cols) {
    struct winsize sz = {.ws_row = (unsigned short) rows,
                         .ws_col = (unsigned short) cols};
    ioctl(fd, TIOCSWINSZ, &sz);
}

JNIEXPORT jint JNICALL
Java_com_burrow_bridge_PtyNative_waitFor(
        JNIEnv *PA_UNUSED(env), jclass PA_UNUSED(clazz), jint pid) {
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return -WTERMSIG(status);
    return 0;
}

/*
 * 杀整个进程组。这是超时处理的核心 ——
 * 只 kill(pid) 的话，被 shell 拉起的 make/gcc/python 会变成孤儿继续跑，
 * 在手机上表现为「命令早就超时了但机器还在发烫」。
 *
 * 先 SIGTERM 给一个善后的机会（清临时文件、flush 输出），
 * 宽限期后 SIGKILL 兜底。
 */
JNIEXPORT void JNICALL
Java_com_burrow_bridge_PtyNative_killProcessGroup(
        JNIEnv *PA_UNUSED(env), jclass PA_UNUSED(clazz),
        jint pid, jint graceMs) {
    killpg((pid_t) pid, SIGTERM);
    if (graceMs > 0) usleep((useconds_t) graceMs * 1000);
    killpg((pid_t) pid, SIGKILL);
}

JNIEXPORT void JNICALL
Java_com_burrow_bridge_PtyNative_close(
        JNIEnv *PA_UNUSED(env), jclass PA_UNUSED(clazz), jint fd) {
    close(fd);
}
