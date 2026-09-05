package com.burrow

import android.app.Activity
import android.app.KeyguardManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import com.burrow.bridge.PtyBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private var pendingImageResult: MethodChannel.Result? = null
    private var pendingImageSlot: String? = null
    private var pendingSkinResult: MethodChannel.Result? = null
    private var pendingCredentialResult: MethodChannel.Result? = null

    /**
     * **在窗口建出来之前**把上次那个防截屏状态装回去。
     *
     * 不这么做就会漏一帧：Dart 那边要先读数据库才知道这个会话该不该保护，
     * 而那时候第一帧内容早就画出去了 —— 用户看到的是"截屏窗口闪了一下"，
     * 而在那一下里截屏是真的能截到的。
     *
     * 所以状态存在 native 这边：上一次设成什么，下一次冷启动的**第一帧**
     * 就是什么。Dart 读完数据库之后再来纠正（多半不用纠正）。
     *
     * 宁可多保护一会儿：装回来的是 true 而实际不需要，代价只是几百毫秒内
     * 截不了图；反过来漏一帧，代价是内容真的被截走了。
     */
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        if (secureStore().getBoolean(KEY_SECURE, false)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onCreate(savedInstanceState)
    }

    private fun secureStore() =
        getSharedPreferences(SECURE_PREFS, Context.MODE_PRIVATE)

    /**
     * **引擎存在进程里，不跟着 Activity 走。**
     *
     * 默认的 FlutterActivity 自己建引擎、自己在 onDestroy 里销毁它。于是
     * Activity 一被重建，Dart 虚拟机就整个没了：内存里那份会话、正在跑的
     * 那一轮请求、滚动位置，全部从零开始 —— 用户看到的是"什么都没操作，
     * 自己回到了新对话"。
     *
     * 而 Activity 重建是**系统随时可以做的事**，不需要用户动一根手指：
     * 没在 `configChanges` 里声明的配置项变一次就重建一次，而那张清单
     * 永远列不全（mcc/mnc、colorMode、以后新增的那些）。所以真正的解法
     * 不是把清单补齐，是让引擎不依赖 Activity 活着。
     *
     * 代价是引擎会一直占着内存直到进程结束。那正是我们要的：后台那一轮
     * 生成也靠它继续跑（见 GenerationService）。
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cached = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (cached != null) return cached
        val engine = FlutterEngine(applicationContext)
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /** 引擎是我们自己存着的，Activity 没了也不许销毁它。 */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // PtyBridge 不是一个 pub 插件，所以不会被自动注册，必须手动加。
        //
        // 引擎复用之后这个方法每次挂载都会走一遍，加之前先看有没有 ——
        // 重复 add 会把上一个实例 detach 掉，而它手里正握着 pty。
        if (!flutterEngine.plugins.has(PtyBridge::class.java)) {
            flutterEngine.plugins.add(PtyBridge())
        }

        // Dart 侧要知道 APK 解出来的 .so 放在哪，才能把 libburrow-launch.so
        // 复制成 $PREFIX/libexec/burrow-launch（见 BootstrapInstaller）。
        // 走 channel 而不是环境变量：Kotlin 改不了已启动的 Dart VM 的进程环境。
        PtyBridge.nativeLibraryDir = applicationInfo.nativeLibraryDir

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SYSTEM_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // OAuth 回跳登录要把授权页交给**外部浏览器**。不能用 WebView：
                // Google 会以 disallowed_useragent 直接拒绝，理由是 WebView 里
                // 宿主 app 能读到用户输入的密码。
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("bad_url", "缺少 url", null)
                    } else {
                        val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(intent)
                            result.success(true)
                        } catch (_: ActivityNotFoundException) {
                            // 没浏览器不是错误：登录页会退回"手动复制这个网址"。
                            result.success(false)
                        }
                    }
                }

                // 唤起系统锁屏验证。只给"忘了会话密码"和"删除锁着的会话"用 ——
                // 日常进会话走 app 自己那道密码，两者不该共用一把钥匙。
                "confirmDeviceCredential" -> {
                    confirmDeviceCredential(call.argument<String>("reason"), result)
                }

                // 生成期间把进程钉住，见 GenerationService。
                "keepAliveStart" -> {
                    try {
                        GenerationService.start(this, call.argument<String>("text"))
                        result.success(true)
                    } catch (e: Exception) {
                        // 起不来不该让这一轮对话失败：没有前台服务只是"退到
                        // 后台可能被杀"，而抛上去会变成一条看不懂的报错气泡。
                        result.success(false)
                    }
                }

                // 防止截屏 / 录屏 / 投屏，也让最近任务里那张缩略图变成空白。
                //
                // 只有窗口这一个开关（FLAG_SECURE），所以它天然是**全窗口**
                // 的：Dart 侧按"当前打开的是哪个会话"来开关它。
                "setSecure" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    try {
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        // 记下来，下次冷启动第一帧就照这个来（见 onCreate）。
                        secureStore().edit().putBoolean(KEY_SECURE, on).apply()
                        result.success(true)
                    } catch (_: Exception) {
                        // 设不上不该让聊天失败。**但也不能谎报成功** ——
                        // 界面要照着返回值说"这台设备上没生效"，
                        // 而不是让用户以为自己被保护着。
                        result.success(false)
                    }
                }

                // 这个 app 现在受不受电池优化限制。
                "batteryOptimizationIgnored" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }

                // 弹系统那个「允许后台运行？」的框。
                "requestIgnoreBatteryOptimizations" -> {
                    result.success(requestIgnoreBatteryOptimizations())
                }

                "keepAliveStop" -> {
                    try {
                        GenerationService.stop(this)
                    } catch (_: Exception) {
                        // 停不掉最多是通知多留一会儿，不值得打断任何事。
                    }
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_PICKER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImage" -> {
                    val slot = call.argument<String>("slot")
                    if (!isImageSlot(slot)) {
                        result.error("invalid_slot", "未知的图片位置", null)
                    } else {
                        openImagePicker(slot!!, result)
                    }
                }

                "pickSkinPack" -> openSkinPicker(result)

                "clearImage" -> {
                    val slot = call.argument<String>("slot")
                    if (!isImageSlot(slot)) {
                        result.error("invalid_slot", "未知的图片位置", null)
                    } else {
                        imageFile(slot!!).delete()
                        temporaryImageFile(slot).delete()
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 弹系统的「确认你的锁屏凭据」。
     *
     * 用 KeyguardManager 而不是 BiometricPrompt：后者要求宿主是
     * FragmentActivity，而换基类会牵动 pty 那一整套 activity result 分发。
     * 系统这个 Intent 本身就覆盖 PIN / 图案 / 密码 / 生物识别。
     *
     * 没设锁屏时返回 `unavailable` 而不是失败：那种情况用户怎么试都过不了，
     * 界面上要能说清楚"去系统设置里加一个锁屏"。
     */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * 请求把这个 app 放进「不受电池优化限制」的名单。
     *
     * 两条路，按顺序试：
     *
     * 1. `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` —— 一个系统弹窗，
     *    点一下就完事。**但有些 ROM 把它锁了**（Google Play 也对这个 action
     *    有品类限制），那时 startActivity 会直接抛。
     * 2. `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` —— 那份名单的设置页。
     *    要用户自己在列表里找到 Burrow，麻烦，但哪儿都能开。
     *
     * 返回值只表示"界面弹出来了"，**不表示用户点了允许** —— 系统不会把结果
     * 回调给我们。Dart 侧要在回到前台之后重新查一次
     * [isIgnoringBatteryOptimizations]，那才是真话。
     */
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(android.net.Uri.parse("package:$packageName"))
        try {
            startActivity(direct)
            return true
        } catch (_: Exception) {
            // 落到设置页那条路。
        }
        return try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        } catch (_: Exception) {
            // 两条都开不了（某些定制 ROM 把这两个页面都删了）。
            // Dart 侧会退回一句"到系统设置里手动找"。
            false
        }
    }

    private fun confirmDeviceCredential(reason: String?, result: MethodChannel.Result) {
        if (pendingCredentialResult != null) {
            result.error("auth_busy", "已经在验证了", null)
            return
        }
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard == null || !keyguard.isDeviceSecure) {
            result.success("unavailable")
            return
        }
        @Suppress("DEPRECATION")
        val intent = keyguard.createConfirmDeviceCredentialIntent(
            reason ?: "验证身份",
            null,
        )
        if (intent == null) {
            result.success("unavailable")
            return
        }
        pendingCredentialResult = result
        try {
            startActivityForResult(intent, REQUEST_CONFIRM_CREDENTIAL)
        } catch (_: ActivityNotFoundException) {
            pendingCredentialResult = null
            result.success("unavailable")
        }
    }

    private fun openImagePicker(slot: String, result: MethodChannel.Result) {
        if (pendingImageResult != null) {
            result.error("picker_busy", "图片选择器已经打开", null)
            return
        }

        pendingImageResult = result
        pendingImageSlot = slot
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_IMAGE)
        } catch (_: ActivityNotFoundException) {
            pendingImageResult = null
            pendingImageSlot = null
            result.error("picker_unavailable", "设备上没有可用的图片选择器", null)
        }
    }

    /**
     * 选一个皮肤包文件。
     *
     * mime 给 * / * 而不是 application/zip：不同文件管理器给 .json 和 .zip 认的
     * mime 各不相同（有的把 .json 报成 text/plain，有的干脆是 octet-stream），
     * 按 mime 过滤的结果是用户明明看得到文件却选不中。扩展名在 Dart 侧校验。
     */
    private fun openSkinPicker(result: MethodChannel.Result) {
        if (pendingSkinResult != null) {
            result.error("picker_busy", "文件选择器已经打开", null)
            return
        }
        pendingSkinResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_SKIN)
        } catch (_: ActivityNotFoundException) {
            pendingSkinResult = null
            result.error("picker_unavailable", "设备上没有可用的文件选择器", null)
        }
    }

    /**
     * 把选中的皮肤包复制进私有目录再把路径交给 Dart。
     *
     * 不直接把 content:// 交过去：Dart 侧的 ZipReader 要一个可 seek 的普通文件
     * （它走 zip 的 central directory 随机读），而 SAF 的 uri 打不开成 File。
     */
    private fun copySkinPack(uri: android.net.Uri, result: MethodChannel.Result) {
        val name = displayName(uri) ?: "skin.zip"
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension !in SKIN_EXTENSIONS) {
            result.error("bad_type", "只支持 .json 或 .zip 皮肤包", null)
            return
        }
        val target = File(File(filesDir, "appearance"), "import.$extension")
        try {
            target.parentFile?.mkdirs()
            // 上次导入留下的另一种扩展名也要清掉，否则 Dart 侧可能读到旧文件。
            SKIN_EXTENSIONS.forEach { File(target.parentFile, "import.$it").delete() }
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("无法打开所选文件")
            input.use { source ->
                target.outputStream().use { destination ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var copied = 0L
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_SKIN_BYTES) {
                            throw IllegalArgumentException("皮肤包不能超过 20 MB")
                        }
                        destination.write(buffer, 0, count)
                    }
                }
            }
            result.success(target.absolutePath)
        } catch (error: Exception) {
            target.delete()
            result.error("skin_copy_failed", error.message ?: "无法读取皮肤包", null)
        }
    }

    private fun displayName(uri: android.net.Uri): String? =
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
        } ?: uri.lastPathSegment

    @Deprecated("FlutterActivity 仍通过 activity result 分发系统选择器结果")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CONFIRM_CREDENTIAL) {
            val result = pendingCredentialResult
            pendingCredentialResult = null
            result?.success(if (resultCode == Activity.RESULT_OK) "ok" else "refused")
            return
        }
        if (requestCode == REQUEST_PICK_SKIN) {
            val result = pendingSkinResult
            pendingSkinResult = null
            if (result == null) return
            if (resultCode != Activity.RESULT_OK) {
                result.success(null)
                return
            }
            val uri = data?.data
            if (uri == null) {
                result.error("missing_file", "没有收到所选文件", null)
                return
            }
            copySkinPack(uri, result)
            return
        }
        if (requestCode != REQUEST_PICK_IMAGE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingImageResult
        val slot = pendingImageSlot
        pendingImageResult = null
        pendingImageSlot = null
        if (result == null || slot == null) return
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }

        val uri = data?.data
        if (uri == null) {
            result.error("missing_image", "没有收到所选图片", null)
            return
        }

        try {
            val target = imageFile(slot)
            val temporary = temporaryImageFile(slot)
            target.parentFile?.mkdirs()
            temporary.delete()
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("无法打开所选图片")
            input.use { source ->
                temporary.outputStream().use { destination ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var copied = 0L
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_IMAGE_BYTES) {
                            throw IllegalArgumentException("图片不能超过 30 MB")
                        }
                        destination.write(buffer, 0, count)
                    }
                }
            }
            if (target.exists() && !target.delete()) {
                throw IllegalStateException("无法替换旧图片")
            }
            if (!temporary.renameTo(target)) {
                temporary.copyTo(target, overwrite = true)
                temporary.delete()
            }
            result.success(target.absolutePath)
        } catch (error: Exception) {
            temporaryImageFile(slot).delete()
            result.error("image_copy_failed", error.message ?: "无法保存图片", null)
        }
    }

    private fun imageFile(slot: String): File =
        File(File(filesDir, "appearance"), "$slot.image")

    private fun temporaryImageFile(slot: String): File =
        File(File(filesDir, "appearance"), ".$slot.tmp")

    private fun isImageSlot(slot: String?): Boolean = slot in IMAGE_SLOTS

    companion object {
        private const val MEDIA_PICKER_CHANNEL = "com.burrow/media_picker"
        /** 缓存引擎的 key。整个进程只有这一个引擎。 */
        private const val ENGINE_ID = "burrow.engine"

        private const val SECURE_PREFS = "burrow_window"
        private const val KEY_SECURE = "secure"

        private const val SYSTEM_CHANNEL = "com.burrow/system"
        private const val REQUEST_PICK_IMAGE = 0xB012
        private const val REQUEST_PICK_SKIN = 0xB013
        private const val REQUEST_CONFIRM_CREDENTIAL = 0xB014
        private const val MAX_IMAGE_BYTES = 30L * 1024L * 1024L
        private const val MAX_SKIN_BYTES = 20L * 1024L * 1024L
        private val SKIN_EXTENSIONS = listOf("json", "zip")
        private val IMAGE_SLOTS = setOf(
            "wallpaper",
            "assistant_avatar",
            "user_avatar",
        )
    }
}
