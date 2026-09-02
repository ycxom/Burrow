package com.burrow

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import com.burrow.bridge.PtyBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private var pendingImageResult: MethodChannel.Result? = null
    private var pendingImageSlot: String? = null
    private var pendingSkinResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // PtyBridge 不是一个 pub 插件，所以不会被自动注册，必须手动加。
        flutterEngine.plugins.add(PtyBridge())

        // Dart 侧要知道 APK 解出来的 .so 放在哪，才能把 libburrow-launch.so
        // 复制成 $PREFIX/libexec/burrow-launch（见 BootstrapInstaller）。
        // 走 channel 而不是环境变量：Kotlin 改不了已启动的 Dart VM 的进程环境。
        PtyBridge.nativeLibraryDir = applicationInfo.nativeLibraryDir

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
        private const val REQUEST_PICK_IMAGE = 0xB012
        private const val REQUEST_PICK_SKIN = 0xB013
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
