# 发布 Pixdraft 更新

发布时使用 `vX.Y.Z` 正式 Release 标签，并上传对应的安装包。在仓库根目录使用 Python 3.11+ 和 OpenSSL 3+ 运行 [签名脚本](sign_update.py)，生成更新清单。

```sh
python3 tool/sign_update.py v1.1.0 notes.md --out release \
  --android Pixdraft-android.apk --macos Pixdraft-macos.dmg
```

将生成的 `pixdraft-update.json` 和 `pixdraft-update.json.sig` 与安装包上传到同一个 GitHub Release。多个安装包可重复传入平台参数。

签名脚本默认读取仓库外 `../pixdraft-signing/` 的 `update-release.pem` 和 `update-release.pass`，也可用 `--signing-dir` 指定目录。发布签名私钥需要与客户端内置公钥对应。
