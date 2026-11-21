# 示例插件：给图片加水印

这个示例在原生端给图片添加文字水印。它不联网，也不申请凭据。

## 打包与安装

在仓库根目录执行：

```sh
(cd examples/plugins/example-stamp && zip -r ../example-stamp-1.0.0.zip plugin.json index.js)
```

在「设置 → 插件」导入 `examples/plugins/example-stamp-1.0.0.zip`。确认清单未申请任何域名后，手动启用插件；刚导入的插件默认停用。

打开「设置 → 图片工具」，通过「从作品选择」或「本地图片」添加一张图，再选「示例水印工具」。输入水印文字并运行，检查处理结果。

## 从哪里改起

- [`plugin.json`](plugin.json) 声明处理器、工具、参数和权限。
- [`index.js`](index.js) 中的 `stamp()` 读取参数，返回水印操作。图片由宿主处理，脚本不用读写图片文件。

要编写其他处理器或联网的供应商插件，见[插件开发指南](../../../docs/plugins.md)。
