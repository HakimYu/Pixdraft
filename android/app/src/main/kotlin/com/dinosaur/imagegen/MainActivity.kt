package com.dinosaur.imagegen

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mediaExecutor = Executors.newSingleThreadExecutor()
    private var pendingBackup: Pair<List<String>, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "image_gen/media")
            .setMethodCallHandler { call, result ->
                if (call.method == "saveBackupToDownloads") {
                    val paths = call.argument<List<String>>("paths")
                    if (paths.isNullOrEmpty()) {
                        result.error("invalid_backup", "没有可保存的备份文件", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
                        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                    ) {
                        saveBackupToDownloads(paths, result)
                    } else if (pendingBackup != null) {
                        result.error("save_pending", "正在等待存储权限，请稍后重试", null)
                    } else {
                        pendingBackup = paths to result
                        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 201)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "saveToGallery") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val mime = call.argument<String>("mime")
                if (path == null || mime !in listOf("image/png", "image/jpeg", "image/webp", "image/gif")) {
                    result.error("invalid_image", "图片格式无效", null)
                    return@setMethodCallHandler
                }
                mediaExecutor.execute {
                    var target: android.net.Uri? = null
                    try {
                        val source = gallerySource(path, File(applicationInfo.dataDir))
                        val values = ContentValues().apply {
                            put(MediaStore.Images.Media.DISPLAY_NAME, "image_${System.currentTimeMillis()}.${source.extension}")
                            put(MediaStore.Images.Media.MIME_TYPE, mime)
                            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/生图")
                            put(MediaStore.Images.Media.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                            ?: error("无法创建相册图片")
                        target = uri
                        val output = contentResolver.openOutputStream(uri) ?: error("无法写入相册")
                        output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
                        values.clear()
                        values.put(MediaStore.Images.Media.IS_PENDING, 0)
                        check(contentResolver.update(uri, values, null, null) == 1) { "无法发布相册图片" }
                        runOnUiThread { result.success(true) }
                    } catch (error: Exception) {
                        target?.let { runCatching { contentResolver.delete(it, null, null) } }
                        val message = when (error) {
                            is IllegalArgumentException -> "无法读取本地图片，请确认图片仍在应用中"
                            is SecurityException -> "系统拒绝写入相册，请改用文件保存"
                            else -> "相册保存失败，请检查存储空间或改用文件保存"
                        }
                        runOnUiThread { result.error("save_failed", message, null) }
                    }
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 201) return
        val (paths, result) = pendingBackup ?: return
        pendingBackup = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            saveBackupToDownloads(paths, result)
        } else {
            result.error("storage_permission", "请允许存储权限后重新导出备份", null)
        }
    }

    private fun saveBackupToDownloads(paths: List<String>, result: MethodChannel.Result) {
        mediaExecutor.execute {
            val downloads = mutableListOf<Uri>()
            val published = mutableListOf<File>()
            var staging: File? = null
            try {
                val sources = paths.map { gallerySource(it, cacheDir) }
                require(sources.map { it.name }.distinct().size == sources.size && sources.all {
                    it.name.startsWith("image-gen-backup-") &&
                        (it.extension == "zip" || it.extension == "igbackup" || it.extension.matches(Regex("part[0-9]{4,}")))
                })
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    for (source in sources) {
                        val values = ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, source.name)
                            put(MediaStore.Downloads.MIME_TYPE, if (source.extension == "zip") "application/zip" else "application/octet-stream")
                            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/image-gen-backup")
                            put(MediaStore.Downloads.IS_PENDING, 1)
                        }
                        val uri = contentResolver.insert(collection, values) ?: error("无法创建备份文件")
                        downloads.add(uri)
                        val output = contentResolver.openOutputStream(uri) ?: error("无法写入备份文件")
                        output.use { stream -> source.inputStream().use { it.copyTo(stream) } }
                    }
                    val ready = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
                    for (uri in downloads) {
                        check(contentResolver.update(uri, ready, null, null) == 1) { "无法发布备份文件" }
                    }
                } else {
                    @Suppress("DEPRECATION")
                    val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "image-gen-backup")
                    check(directory.isDirectory || directory.mkdirs()) { "无法创建备份目录" }
                    val work = File(directory, ".backup-${java.util.UUID.randomUUID()}")
                    check(work.mkdir()) { "无法创建备份暂存目录" }
                    staging = work
                    for (source in sources) source.copyTo(File(work, source.name))
                    for (source in sources) {
                        val target = File(directory, source.name)
                        check(!target.exists() && File(work, source.name).renameTo(target)) {
                            "无法发布备份文件"
                        }
                        published.add(target)
                    }
                }
                runOnUiThread { result.success(null) }
            } catch (_: Exception) {
                downloads.forEach { runCatching { contentResolver.delete(it, null, null) } }
                published.forEach { runCatching { it.delete() } }
                runOnUiThread { result.error("backup_save_failed", "无法保存备份，请检查下载目录权限和可用空间", null) }
            } finally {
                staging?.let { runCatching { it.deleteRecursively() } }
            }
        }
    }

    override fun onDestroy() {
        mediaExecutor.shutdown()
        super.onDestroy()
    }
}
