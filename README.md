# Codex 手机版安装与稳定通道

## 已安装 Codex，只修复 App 命令超时

在 Termux 执行：

```bash
curl -L -o ~/setup-exec-bridge.sh "https://raw.githubusercontent.com/qing222ddd/codex-mobile-setup/main/setup-exec-bridge.sh" && bash ~/setup-exec-bridge.sh
```

脚本会配置稳定的本地命令服务、唤醒锁、`codex-start` 和 App 专用 `ask-codex.sh`。

## 全新安装 Codex

运行仓库里的 `install.sh`，然后按手机上的中文提示操作。

## 常用命令

```bash
codex-start
```

启动命令服务和 Codex。

```bash
curl http://127.0.0.1:8898/ping
```

返回 `pong` 表示 App 命令服务在线。
