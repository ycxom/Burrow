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

    @Deprecated("FlutterActivity 仍通过 activity result 分发系统选择器结果")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
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
        private const val MAX_IMAGE_BYTES = 30L * 1024L * 1024L
        private val IMAGE_SLOTS = setOf(
            "wallpaper",
            "assistant_avatar",
            "user_avatar",
        )
    }
}
