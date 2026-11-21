# Web 部署与存储

部署整个 `build/web/`，确保 `sqflite_sw.js` 和 `sqlite3.wasm` 与应用入口在同一目录。用 HTTPS 或 `localhost` 打开，不要用 `file://`。供应商和图片站点也要允许来自工作台的跨域请求（CORS）；否则请使用原生端。

## 换地址或浏览器前先备份

工作台把 `studio.db` 存在浏览器的 IndexedDB 中。数据按同源隔离：协议、域名或端口任一变化，或换了浏览器配置文件，旧数据都不会自动迁移。清除站点数据会删除本地资料。

同一站点只打开一个工作台标签页，生成时保持页面开启。缺少 SharedWorker 的浏览器会改用独立 Worker，无法让多个标签页同时写入；应用会在打开数据库和恢复任务前取得同源的单窗口锁。

## 浏览器凭据

API Key 不写入 SQLite。[flutter_secure_storage_web 2.1.1](https://pub.dev/packages/flutter_secure_storage_web/versions/2.1.1) 使用 Web Crypto 加密密钥，默认将密文和用于解密的密钥保存在同一站点的浏览器存储中。它无法防止同源脚本注入，也无法抵御能读取页面数据的扩展或能访问本地浏览器存储的人。

## 重新生成 SQLite 资源

- `sqflite_sw.js` 由 [sqflite_common_ffi_web 1.2.2](https://pub.dev/packages/sqflite_common_ffi_web/versions/1.2.2) 的官方 setup 生成。生成时使用 `sqflite_common` 2.5.17、`sqflite_common_ffi` 2.4.7、`sqlite3` 3.9.1 和 `webdev` 4.0.3。
- `sqlite3.wasm` 来自 [sqlite3.dart 3.9.1](https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/sqlite3.wasm)，与生成 worker 时使用的 `sqlite3` 版本一致。

在仓库根目录运行：

```sh
dart run sqflite_common_ffi_web:setup --force \
  --sqlite3-wasm-url https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.9.1/sqlite3.wasm
```

## 运行 Web 存储测试

Flutter 的浏览器测试服务器从 `test/` 提供静态文件。先将两项资源临时链接到 `test/sqflite_sw.js` 和 `test/sqlite3.wasm`，再运行：

```sh
flutter test --platform chrome test/data/studio_store_web_test.dart
```

测试结束后移除这两个链接。
