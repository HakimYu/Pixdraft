package com.dinosaur.imagegen

import java.io.File
import java.nio.file.Files

// 无 Android 运行时依赖，可与 GallerySource.kt 一起用 kotlinc 编译运行。
fun main() {
    val temporary = Files.createTempDirectory("gallery-source-check").toFile()
    try {
        val user = File(temporary, "data/user/0").apply { mkdirs() }
        val app = File(user, "app").apply { mkdirs() }
        val image = File(app, "files/image.png").apply { parentFile.mkdirs(); writeText("image") }
        val alias = File(temporary, "data/data")
        Files.createSymbolicLink(alias.toPath(), user.toPath())
        check(gallerySource(image.path, File(alias, "app")) == image.canonicalFile)
        check(gallerySource(File(alias, "app/files/image.png").path, app) == image.canonicalFile)

        val outside = File(user, "app-other/image.png").apply { parentFile.mkdirs(); writeText("outside") }
        check(runCatching { gallerySource(outside.path, app) }.isFailure)
        check(runCatching { gallerySource(File(app, "../app-other/image.png").path, app) }.isFailure)
        val escape = File(app, "escape.png")
        Files.createSymbolicLink(escape.toPath(), outside.toPath())
        check(runCatching { gallerySource(escape.path, app) }.isFailure)
        check(runCatching { gallerySource(File(app, "missing.png").path, app) }.isFailure)
        check(runCatching { gallerySource(app.path, app) }.isFailure)
        println("GallerySource: 别名路径、越界路径、软链接、缺失文件与目录检查通过")
    } finally {
        temporary.deleteRecursively()
    }
}
