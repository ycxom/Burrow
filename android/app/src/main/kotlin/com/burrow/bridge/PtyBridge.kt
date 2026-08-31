package com.burrow.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * pty 的 JNI 声明。对应 android/app/src/main/cpp/pty.c。
 * 方法签名和 termux 的 [com.termux.terminal.JNI] 保持一致，
 * 便于日后想换回 termux 的 TerminalView 时直接对接。
 */
internal object PtyNative {
    init { System.loadLibrary("burrow") }

    external fun createSubprocess(
        cmd: String, cwd: String?, args: Array<String>, envVars: Array<String>,
        processId: IntArray, rows: Int, columns: Int
    ): Int

    external fun setPtyWindowSize(fd: Int, rows: Int, cols: Int)
    external fun waitFor(pid: Int): Int

    /** 杀整个进程组。超时处理必须用它，见 pty.c 里的说明。 */
    external fun killProcessGroup(pid: Int, graceMs: Int)

    external fun close(fd: Int)
}

/**
 * 一个 pty 会话。
 *
 * 每个会话独占两条线程：
 *   - reader：阻塞在 read(ptmx)，把字节推给 EventChannel
 *   - waiter：阻塞在 waitpid，拿到退出码后收尾
 *
 * 用线程而不是协程/NIO，是因为 pty 的 fd 在 Android 上不支持 epoll 的
 * 边缘触发语义（它是字符设备），非阻塞轮询反而更费电。两条阻塞线程更简单也更省。
 */
internal class PtySession(
    val id: Int,
    argv: List<String>,
    env: Map<String, String>,
    cwd: String,
    rows: Int,
    cols: Int,
    private val onOutput: (ByteArray) -> Unit,
    private val onExit: (Int) -> Unit,
) {
    private val pidHolder = IntArray(1)
    private val fd: Int
    val pid: Int get() = pidHolder[0]

    // 必须声明在 init 之前 —— Kotlin 的属性初始化是按源码顺序走的，
    // 在 init 里给一个后面才声明的属性赋值是编译错误。
    private val outputStream: FileOutputStream

    @Volatile private var closed = false

    init {
        fd = PtyNative.createSubprocess(
            argv.first(),
            cwd,
            argv.toTypedArray(),
            env.map { "${it.key}=${it.value}" }.toTypedArray(),
            pidHolder,
            rows,
            cols,
        )

        // Java 不提供从 int 造 FileDescriptor 的公开途径，只能反射写它的
        // descriptor 字段。termux 的 TerminalSession 用的是同一招。
        // 这个字段自 JDK 1.0 起就叫这个名字，Android 上也一样，很稳。
        val fileDescriptor = FileDescriptor().also { descriptor ->
            FileDescriptor::class.java.getDeclaredField("descriptor").apply {
                isAccessible = true
                setInt(descriptor, fd)
            }
        }

        // 先建好写端再起读线程：读线程一旦拿到输出就可能触发上层立刻回写，
        // 那时 outputStream 必须已经可用。
        outputStream = FileOutputStream(fileDescriptor)

        Thread({
            val input = FileInputStream(fileDescriptor)
            // 4KB：一次 read 的典型上限，再大也填不满，还平白多占内存。
            val buf = ByteArray(4096)
            try {
                while (!closed) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    onOutput(buf.copyOf(n))
                }
            } catch (_: Exception) {
                // pty 关闭时 read 抛 EIO，这是正常终止路径，不是错误。
            }
        }, "pty-reader-$id").start()

        Thread({
            val code = PtyNative.waitFor(pid)
            closed = true
            onExit(code)
        }, "pty-waiter-$id").start()
    }

    fun write(data: ByteArray) {
        if (closed) return
        try { outputStream.write(data); outputStream.flush() } catch (_: Exception) {}
    }

    fun resize(rows: Int, cols: Int) {
        if (!closed) PtyNative.setPtyWindowSize(fd, rows, cols)
    }

    /**
     * 终止会话。默认给 500ms 宽限期让子进程善后（flush 输出、删临时文件）。
     * 宽限期太长会让用户觉得「取消按钮没反应」，太短则可能丢掉最后几行输出。
     */
    fun kill(graceMs: Int = 500) {
        if (closed) return
        PtyNative.killProcessGroup(pid, graceMs)
    }

    fun dispose() {
        closed = true
        try { PtyNative.close(fd) } catch (_: Exception) {}
    }
}

/**
 * Flutter 插件。
 *
 * MethodChannel `burrow/pty`:
 *   spawn(argv, env, cwd, rows, cols) -> sessionId
 *   write(sessionId, bytes)
 *   resize(sessionId, rows, cols)
 *   kill(sessionId)
 *   probeSandbox() -> {"seccomp":bool,"landlock_abi":int,"rlimit":bool}
 *
 * EventChannel `burrow/pty/events`:
 *   {"session":id, "type":"data", "bytes":[...]}
 *   {"session":id, "type":"exit", "code":n}
 *
 * 用一条共享的 EventChannel 而不是每个会话一条：Flutter 的 channel 创建
 * 有固定开销，而 Agent 场景下会话是高频短命的（每条命令一个）。
 */
class PtyBridge : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    companion object {
        /**
         * APK 解压出来的 .so 所在目录（applicationInfo.nativeLibraryDir）。
         * 由 MainActivity 在 configureFlutterEngine 里写入。
         *
         * 用 companion 而不是构造参数：PtyBridge 是被 flutterEngine.plugins.add()
         * 拿去用的，注册时机比 Activity 拿到 applicationInfo 更早。
         */
        @Volatile
        var nativeLibraryDir: String? = null
    }

    private lateinit var method: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    private val sessions = ConcurrentHashMap<Int, PtySession>()
    private val nextId = AtomicInteger(1)

    /** $PREFIX/libexec/burrow-launch 的路径，由 Dart 侧在初始化时设进来。 */
    private var launcherPath: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        method = MethodChannel(binding.binaryMessenger, "burrow/pty")
        method.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "burrow/pty/events")
        events.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sessions.values.forEach { it.kill(0); it.dispose() }
        sessions.clear()
        method.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        this.sink = sink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(payload: Map<String, Any?>) {
        // EventSink 只能在主线程调用，而 reader/waiter 都是后台线程。
        main.post { sink?.success(payload) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setLauncher" -> {
                launcherPath = call.argument<String>("path")
                result.success(null)
            }

            "spawn" -> {
                val argv = call.argument<List<String>>("argv") ?: emptyList()
                if (argv.isEmpty()) {
                    result.error("EMPTY_ARGV", "argv 不能为空", null); return
                }
                val id = nextId.getAndIncrement()
                try {
                    sessions[id] = PtySession(
                        id = id,
                        argv = argv,
                        env = call.argument<Map<String, String>>("env") ?: emptyMap(),
                        cwd = call.argument<String>("cwd") ?: "/",
                        rows = call.argument<Int>("rows") ?: 24,
                        cols = call.argument<Int>("cols") ?: 80,
                        onOutput = { bytes ->
                            emit(mapOf("session" to id, "type" to "data", "bytes" to bytes))
                        },
                        onExit = { code ->
                            emit(mapOf("session" to id, "type" to "exit", "code" to code))
                            sessions.remove(id)?.dispose()
                        },
                    )
                    result.success(id)
                } catch (e: Exception) {
                    result.error("SPAWN_FAILED", e.message, null)
                }
            }

            "write" -> {
                val id = call.argument<Int>("session")!!
                sessions[id]?.write(call.argument<ByteArray>("bytes") ?: ByteArray(0))
                result.success(null)
            }

            "resize" -> {
                val id = call.argument<Int>("session")!!
                sessions[id]?.resize(
                    call.argument<Int>("rows") ?: 24,
                    call.argument<Int>("cols") ?: 80,
                )
                result.success(null)
            }

            "kill" -> {
                val id = call.argument<Int>("session")!!
                sessions[id]?.kill(call.argument<Int>("graceMs") ?: 500)
                result.success(null)
            }

            "nativeLibraryDir" -> result.success(nativeLibraryDir)

            // Build.SUPPORTED_ABIS[0] 是这台设备**实际运行**本进程的 ABI。
            // 不用 Build.CPU_ABI（已废弃），也不用 SUPPORTED_64_BIT_ABIS ——
            // 一台 arm64 设备上如果 APK 只带了 32 位库，进程就是 32 位的，
            // 那时该下的是 armhf 的 rootfs 而不是 arm64 的。
            "abi" -> result.success(android.os.Build.SUPPORTED_ABIS.firstOrNull())

            "probeSandbox" -> {
                // 跑一次 `burrow-launch --probe`，让原生自己报告能力。
                // 不在 Kotlin 里判断内核版本 —— 版本号和实际编译选项经常对不上，
                // 真去调一次 syscall 才是唯一可靠的答案。
                val path = launcherPath
                if (path == null) {
                    result.success(mapOf(
                        "seccomp" to false, "landlock_abi" to 0, "rlimit" to true))
                    return
                }
                try {
                    val p = ProcessBuilder(path, "--probe")
                        .redirectErrorStream(true).start()
                    val out = p.inputStream.bufferedReader().readText().trim()
                    p.waitFor()
                    result.success(mapOf(
                        "seccomp" to out.contains("\"seccomp\":true"),
                        // 括号不能省：`to` 的优先级高于 `?:`，写成
                        // `"k" to X ?: 0` 会被解析成 `("k" to X) ?: 0`，
                        // 整个表达式的类型退化成 Serializable，编译不过。
                        "landlock_abi" to (Regex("\"landlock_abi\":(\\d+)")
                            .find(out)?.groupValues?.get(1)?.toInt() ?: 0),
                        "rlimit" to true,
                    ))
                } catch (e: Exception) {
                    result.success(mapOf(
                        "seccomp" to false, "landlock_abi" to 0, "rlimit" to true))
                }
            }

            else -> result.notImplemented()
        }
    }
}
