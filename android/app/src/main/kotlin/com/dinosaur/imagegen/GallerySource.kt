package com.dinosaur.imagegen

import java.io.File

internal fun gallerySource(path: String, dataDirectory: File): File {
    val source = File(path).canonicalFile
    // /data/data 等别名在部分设备上指向 /data/user/0，两边必须同样解析。
    val root = dataDirectory.canonicalFile.path + File.separator
    require(source.path.startsWith(root) && source.isFile) { "无法读取本地图片" }
    return source
}
