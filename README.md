# Port Forward Studio

一个面向 macOS 的原生 SSH 本地端口转发工具。使用 SwiftUI 构建，无第三方运行时依赖。

## 功能

- 创建、编辑、删除多条 SSH 本地转发（`-L`）和反向转发（`-R`）配置
- 每条隧道独立启动和关闭，并显示连接错误
- 自定义 SSH 服务器、端口、用户名、密码、本地监听和远程目标
- 配置自动保存；密码只保存在 macOS 钥匙串，不会写入 JSON
- 支持 `ssh-agent` / `~/.ssh/config` 自动认证
- 支持选择指定私钥，并交互输入加密私钥口令
- 密码和密钥口令可选择保存到 macOS 钥匙串
- 实时展示每条隧道的上传、下载和总流量
- 最近 60 秒上传/下载每秒数据量折线图
- 默认只监听本机，同时可显式选择对局域网开放

## 系统要求

- macOS 13 或更高版本
- Xcode Command Line Tools（包含 Swift 和系统 OpenSSH）

## 运行

开发模式：

```bash
swift run
```

构建可双击运行的应用：

```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
open ".build/Port Forward Studio.app"
```

应用配置保存在：

```text
~/Library/Application Support/PortForwardStudio/profiles.json
```

密码或密钥口令存储在 macOS 钥匙串服务 `com.portforwardstudio.ssh-password` 中。

## 使用方法

1. 点击工具栏的 `+`。
2. 填写 SSH 服务器地址、端口和用户名，并选择自动、密码或指定私钥认证。
3. 选择转发方向并填写监听端和目标端：
   - 本地转发：Mac 监听端口，连接 SSH 服务器侧可访问的目标。
   - 反向转发：SSH 服务器监听端口，连接 Mac 侧可访问的目标。
4. 点击“启动转发”。本地转发通过 Mac 的监听端口访问；反向转发通过 SSH 服务器的监听端口访问。

反向转发默认只在 SSH 服务器的 `127.0.0.1` 上监听。选择 `0.0.0.0` 时，服务端必须在 `sshd_config` 中允许 `GatewayPorts`，并放行相应防火墙端口。

首次连接新服务器时，应用使用 OpenSSH 的 `accept-new` 策略记录主机密钥；若服务器已有主机密钥发生变化，连接会被拒绝并显示 SSH 错误。

## 测试

```bash
swift test
```

流量统计计算经过应用本地计量代理的 TCP 载荷字节数，不包含 SSH 协议本身的加密和握手开销。关闭隧道后，本次会话统计归零。
