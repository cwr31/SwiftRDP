# SwiftRDP

[English](README.md) | 简体中文

SwiftRDP 是一个使用 Swift 编写的原生 macOS RDP 服务端和屏幕共享应用。

## 功能

- 支持 TLS，以及可选的 CredSSP/NLA 身份验证。
- 使用 macOS 原生能力捕获屏幕，并注入远程键盘和鼠标输入。
- 支持 Bitmap、H.264 和渐进式 RemoteFX 显示路径。
- 自适应视频传输，可配置画质和帧率。
- 支持文本、图片和文件剪贴板同步。
- 支持将系统音频转发到 RDP 客户端。
- 支持选择物理显示器，以及可选的虚拟显示器模式。
- 提供菜单栏应用、连接历史、记住的连接设置和日志查看。

## 环境要求

- macOS 26.0 或更高版本。
- Swift 6.2 或兼容的 Xcode 工具链。
- 支持 RDP 的客户端，例如 Microsoft Remote Desktop 或 Windows `mstsc`。

Swift Package Manager 会自动解析 SwiftNIO 和 SwiftNIO SSL 依赖。

## 构建和测试

```bash
git clone https://github.com/cwr31/SwiftRDP.git
cd SwiftRDP
swift test
swift build -c release --product SwiftRDPApp
```

开发时也可以直接运行命令行服务端：

```bash
swift run swift-rdp --user user --password 'choose-a-password'
```

命令行参数可能会被本机的进程查看工具看到，因此不要在这里使用真实账户
密码。

## 打包并运行 macOS 应用

应用需要“屏幕录制”和“辅助功能”权限，才能捕获桌面并注入远程输入。请使用
安装脚本生成真正的 `.app` 包，并使用非 ad-hoc 的 Apple Development 证书签名：

```bash
cp scripts/local-signing.env.example .swift-rdp.local.env
chmod 600 .swift-rdp.local.env
bash scripts/install-and-run.sh
```

脚本会将应用安装到 `~/Applications/SwiftRDP.app`，保持 Bundle ID 不变，验证签名
后启动应用。没有配置签名身份时，脚本会自动选择第一张 Apple Development 证书。
如果本机有多张证书，可以在 `.swift-rdp.local.env` 中设置
`SWIFTRDP_SIGN_IDENTITY`；设置 `SWIFTRDP_EXPECTED_TEAM_ID` 可以固定本机 Team ID，
让 macOS 的隐私权限在更新应用后继续保留。

本地签名配置和构建输出已被 Git 忽略。不要提交钥匙串密码、证书、私钥、生成的
服务端证书，或 `~/Library/Application Support/SwiftRDP` 下的文件。

## 连接方式

1. 在 Mac 上启动 SwiftRDP。
2. 如果系统提示，请在“系统设置”中授予屏幕录制和辅助功能权限。
3. 在 RDP 客户端中连接 Mac 的 IP 地址和 `3389` 端口。
4. 使用 SwiftRDP 设置中显示的用户名和密码。

GUI 应用第一次启动时会生成随机密码。独立命令行目标使用开发环境默认值，因此
在可信局域网之外使用前必须显式设置凭据。建议使用 VPN 或防火墙，不要直接把
RDP 端口暴露到公网。

## 运行时数据

SwiftRDP 会在仓库之外生成自签名 TLS 证书和身份验证缓存：

```text
~/Library/Application Support/SwiftRDP/certs/
~/Library/Application Support/SwiftRDP/ntlm/
~/Library/Logs/SwiftRDP/
```

这些文件与本机相关，应保持私密。

## 参与贡献

提交修改时，尽量同时添加针对性的测试。提交 Pull Request 前请运行完整测试套件：

```bash
swift test
```

## 许可证

SwiftRDP 使用 [MIT License](LICENSE) 授权。
