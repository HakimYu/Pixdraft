# 插件开发指南

先试一遍[示例水印插件](../examples/plugins/example-stamp/README.md)，再按需编写自己的工具或生图适配器。动态插件只在原生端运行：将 `plugin.json` 和入口脚本打成 ZIP，在「设置 → 插件」导入并启用。

内置插件 `builtin.providers` 提供 `images`、`responses`、`wavespeed`、`evolink` 四个适配器，`builtin.local-tools` 提供缩放和水印。内置版本固定为 `1.0.0`，可禁用，不可卸载。动态适配器按 `ProviderConfig.adapterId` 匹配（未设置时使用 `protocol.name`）；缺少适配器时会报错，不会换用内置适配器。

## 清单 `plugin.json`

```json
{
  "id": "com.example.stamp",
  "name": "示例水印插件",
  "version": "1.0.0",
  "apiVersion": 1,
  "entry": "index.js",
  "permissions": {"credentials": [], "image": true},
  "providers": [],
  "processors": [{"id": "example.stamp", "name": "示例水印", "process": "stamp", "fields": []}],
  "tools": [{"id": "tool.stamp", "name": "示例水印工具", "processorId": "example.stamp", "fields": []}]
}
```

宿主按以下规则校验清单和 ZIP：

- `id`：小写点分名称（如 `com.example.upscale`），不能是内置保留 ID。
- `version`：`x.y.z` 纯数字。
- `apiVersion`：必须等于宿主支持的 `pluginApiVersion`（当前 `1`）。
- `entry`：包内 `.js` 相对路径，不含 `..`、不以 `/` 开头。
- `permissions.credentials`：授权域名，小写主机名，不允许通配符、端口、路径。
- `permissions.image`：处理器是否可读写图片（缺省 `true`）。
- 扩展 ID 在全插件内唯一；工具引用的 `processorId` 必须存在；函数名必须是合法 JS 标识符。
- 扩展 ID 跨插件唯一：同一 `adapterId` / 处理器 ID / 工具 ID 只能属于一个插件，别的插件（哪怕版本号更高、或原插件已被禁用/卸载）不能接管。
- 内置扩展 ID（`images`、`responses`、`wavespeed`、`evolink`、`local.resize`、`local.watermark`、`tool.resize`、`tool.watermark`）是保留名，动态插件不得声明。
- 至少声明一个 provider / processor / tool。
- 包体 ≤ 16 MiB，文件数 ≤ 100，解压后 ≤ 32 MiB，入口 ≤ 8 MiB，入口必须是 UTF-8。
- 中央目录先校验：重复条目名、符号链接、条目数/声明解压大小、路径逃逸都在解码任何条目之前拒绝；随后仍做 CRC 严格校验。

## 安装与生命周期

- `PluginManager.inspect(bytes)`：只做静态校验并返回清单，不落盘、不执行脚本。导入前用它让用户确认域名与声明。
- `PluginManager.install(bytes)`：完整校验通过后解包到 `<app>/plugins/<id>/<version>`，先写 `.incoming-*` 再原子 rename；同一 `id@version` 已存在但内容不同（`sha256` 对比，记录在 `.package-hash`）时拒绝，要求提升版本号。失败会回滚到 `.previous-*`，旧版本保持可用。
- 安装前拒绝扩展身份冲突：与已装插件（含已禁用/已卸载但保留在磁盘的版本）撞同一个扩展 ID 时整包拒绝，不会把别人的扩展当自己的升级。
- **初装默认未启用**：导入后必须显式 `setEnabled(id, true)`。
- `PluginManager.uninstall(id)`：移除索引条目（不再进新任务的可选项），**保留磁盘上的版本目录**，已 pin 到该版本的任务仍能跑完。内置插件不可卸载。
- `PluginManager.list()` 返回内置 + 已安装动态插件，`InstalledPlugin.enabled` 反映启用状态。

## 排队任务如何选择版本

任务在入队前通过 `PluginRegistry.pinInput(input)` 把 `provider.adapterVersion` 与每个 `ProcessingStep.version` 固定下来。

- 未 pin 时取**已启用**插件里的最高版本。
- pin 了版本就必须精确命中；缺失时报「缺少版本 X（已安装：…），不会自动换版」。
- 已禁用或已卸载但磁盘保留的版本，会为 pin 到它的任务按需编译一次（`_inactive`），不影响新任务的可选项。
- 已禁用的插件不会出现在 `providers` / `processors` / `tools` 列表里；**新提交**在 `pinInput` 门口被拒绝（「插件已禁用，不能提交新任务」），而排队中/已领取的任务继续按 pin 住的旧版快照执行，不会被禁用打断。

## 脚本 SDK

入口脚本由 QuickJS 执行。可以使用 `JSON`、`Math`、`String` 等标准库，但没有 `fetch`、`XMLHttpRequest`、`WebSocket`、`require` 或 `process`。脚本不能直接访问宿主的 Dart 对象、文件系统、数据库或凭据。

### 处理器 / 工具

```js
function stamp(payload) {
  var text = payload.params.text || '默认文字';
  return {operations: [{operation: 'watermark', params: {text: text, position: '右下', opacity: 0.6}}]};
}
```

- 入参：`{params, image: {id, mime, width, height, bytes}}`，其中 `bytes` 是字节数，不是图片内容。
- 返回：`{operations: [{operation, params}]}`，宿主顺序调用本地处理模块（目前 `resize` / `watermark`）
- 脚本不接触图片二进制，全部操作在本地处理层完成
- 单次函数调用超过 5 秒由 QuickJS 中断处理器**硬切断**（同步 `while(true){}` 也会断），内存上限 64 MiB，栈 2 MiB
- 运行时不提供定时器与模块加载，脚本必须是单文件纯函数

### 供应商

```js
function plan(payload) { return {url: payload.provider.baseUrl + '/images', method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify({prompt: payload.prompt})}; }
function interpret(response) { return {images: JSON.parse(response.body).data.map(function (item) { return item.url; })}; }
```

- `plan(payload)`：`{taskId, prompt, count, size, quality, format, references, provider, config}`，参考图以 `dataUrl` 给出（单张 ≤ 8 MiB）
- `interpret(response)`：`{status, headers, body, bodyEncoding}`，可返回 `{images}`、`{request}`（续下一轮，最多 6 轮）、`{error}` 或 `{metadata}`
- 网络由宿主发起：只有清单授权的域名会收到 `Authorization: Bearer <当前凭据>`；HTTP 仅在供应商显式打开「允许不安全连接」时可用
- 重定向最多 3 跳，每一跳都重新校验授权域名，禁止借重定向把凭据带到别处
- 脚本不能设置 `Authorization`、`Cookie`、`Host`、`Content-Length`
- 图片下载只接受 HTTPS、非 IP、非 `localhost`、无 userInfo 的地址，响应 ≤ 32 MiB

## 运行时：jsf（QuickJS）

原生端使用 `jsf` 加载 QuickJS。桌面测试若没有自动加载原生库，将 `JSF_LIBRARY_PATH` 设为已构建的 `libjsf` 文件路径。Android 插件运行仍待真机验收。

## 测试

```sh
flutter test test/plugins/                                   # 清单/管理器/注册表/示例
JSF_LIBRARY_PATH=/path/to/libjsf.so flutter test test/plugins/  # 加上真实脚本执行
```

普通测试覆盖清单校验、ZIP 导入、版本路由和网络授权。提供 QuickJS 原生库后，还可运行脚本执行、中断和示例水印的测试。

## 已知限制

- 脚本没有 `async`/定时器/模块加载，长任务只能靠多轮 `{request}` 往返，不能主动 yield。
- 本地操作只支持 `resize` 与 `watermark`；需要其它操作要先扩展 `local_processing.dart`。
- 清单不支持声明 UI 布局，字段类型只有 `text` / `number` / `select` / `bool`。
- 动态插件目前只有一个入口文件，`entry` 之外的 JS 不会被打包执行。