# 絮语

一个安静、好看的 iPhone 聊天 App：和你的 Claude、Codex 聊天、建群聊、记待办、写日记。
用的是你自己的订阅账号，消息只在你的 iPhone 和你的电脑之间传输。

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| iOS App | `App/` | SwiftUI，iOS 18+，数据存在手机本地（SwiftData） |
| 电脑中继 | `relay/` | Node.js，调用电脑上已登录的 Claude Code 和 Codex |
| 云端打包 | `.github/workflows/ios.yml` | GitHub 的 Mac 机器编译、签名、打出 IPA，并在模拟器里截图 |

## 电脑中继

1. 安装 Node.js、Claude Code、Codex，并各自登录一次。
2. 双击 `relay/start-relay.bat`。
3. 窗口里会显示地址和配对码，在手机「待办 → 右上角设置 → 连接」里填上。

自检：在 `relay` 目录运行 `npm run check`，会让 Claude 和 Codex 各回一句。

## 签名

在 GitHub 仓库的 Settings → Secrets and variables → Actions 里添加：

- `P12_BASE64`：p12 证书的 base64
- `P12_PASSWORD`：p12 密码
- `PROFILE_BASE64`：描述文件（.mobileprovision）的 base64

没有这三个时会打出未签名的 IPA。证书失效后，换掉这三个 Secrets 再运行一次打包即可。
