# 发布 Pixdraft 更新

## GitHub Actions 发布

在仓库的 **Settings → Secrets and variables → Actions** 中添加以下 Repository secrets。使用与现有 Pixdraft 发布相同的签名材料。

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `android-release.p12` 的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | `android-release.pass` 中的密码 |
| `UPDATE_SIGNING_KEY_BASE64` | `update-release.pem` 的 Base64 内容 |
| `UPDATE_SIGNING_PASSWORD` | `update-release.pass` 中的密码 |
| `LINUX_GPG_PRIVATE_KEY` | 用于签署 Linux DEB 的 ASCII armored 私钥 |
| `LINUX_GPG_PASSPHRASE` | Linux GPG 私钥密码，私钥无密码时可省略 |

可以使用 `openssl base64 -A -in <文件>` 生成单行 Base64。Linux 私钥需要是 `gpg --armor --export-secret-keys <指纹>` 的输出。

将[工作流](../.github/workflows/release.yml)合入默认分支后，把 `vX.Y.Z` 标签推到 GitHub 即可发布。标签决定版本号，构建号取自该标签的 `pubspec.yaml`。已有标签可以在 **Actions → Release Pixdraft → Run workflow** 中填写后重新构建，也可以在原运行页面点击 **Re-run all jobs**。

六个平台构建和签名通过后，工作流才更新 Release。同一个标签重跑会覆盖同名产物，保留原 Release 的标题、正文和其他附件。Release 需要允许修改附件。首次发布由 GitHub 生成更新说明。

发布产物包括 Android APK、macOS 通用 DMG、Windows x64 安装程序 `Pixdraft-windows-x64-setup.exe`、Ubuntu 24.04 x64 DEB、Web ZIP 和 iOS/iPadOS IPA。Windows 下载后双击安装。iOS IPA 需要签名后才能安装到真机。Web ZIP 解压后部署到静态站点。

## 手工生成更新清单

发布时使用 `vX.Y.Z` 正式 Release 标签，并上传对应的安装包。在仓库根目录使用 Python 3.11+ 和 OpenSSL 3+ 运行 [签名脚本](sign_update.py)，生成更新清单。

```sh
python3 tool/sign_update.py v1.1.0 notes.md --out release \
  --android Pixdraft-android.apk --macos Pixdraft-macos.dmg
```

将生成的 `pixdraft-update.json` 和 `pixdraft-update.json.sig` 与安装包上传到同一个 GitHub Release。多个安装包可重复传入平台参数。

签名脚本默认读取仓库外 `../pixdraft-signing/` 的 `update-release.pem` 和 `update-release.pass`，也可用 `--signing-dir` 指定目录。发布签名私钥需要与客户端内置公钥对应。
