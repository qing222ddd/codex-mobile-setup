#!/data/data/com.termux/files/usr/bin/bash
# Codex 手机版：稳定命令服务一键修复
# 作用：把 App 调 Termux 的通道从 RUN_COMMAND 改成稳定的本地 HTTP。
set -u

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
BRIDGE_DIR="$HOME_DIR/codex-bridge"
EXEC_URL="https://raw.githubusercontent.com/qing222ddd/codex-mobile-setup/main/exec-server.mjs"

echo "=========================================="
echo "       Codex 手机版稳定通道修复"
echo "=========================================="

if ! command -v node >/dev/null 2>&1; then
  echo "[1/5] 安装 Node.js..."
  pkg install -y nodejs
else
  echo "[1/5] Node.js 已安装"
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "[2/5] 安装 curl..."
  pkg install -y curl
else
  echo "[2/5] curl 已安装"
fi

mkdir -p "$BRIDGE_DIR"
echo "[3/5] 下载命令服务..."
curl -L --retry 5 --retry-delay 2 --connect-timeout 20 \
  -o "$BRIDGE_DIR/exec-server.mjs.tmp" "$EXEC_URL" || {
    echo "下载失败，请检查网络后重跑。"
    exit 1
  }
mv -f "$BRIDGE_DIR/exec-server.mjs.tmp" "$BRIDGE_DIR/exec-server.mjs"

cat > "$BRIDGE_DIR/start-exec.sh" <<'EXEC_START'
#!/data/data/com.termux/files/usr/bin/bash
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
BRIDGE_DIR="$HOME/codex-bridge"

# 防止 Android 16 把 Termux 后台冻结。
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 || true
fi

if curl -fsS --max-time 1 http://127.0.0.1:8898/ping 2>/dev/null | grep -q '^pong$'; then
  exit 0
fi

pkill -f "$BRIDGE_DIR/exec-server.mjs" >/dev/null 2>&1 || true
nohup node "$BRIDGE_DIR/exec-server.mjs" > "$BRIDGE_DIR/exec.log" 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  if curl -fsS --max-time 1 http://127.0.0.1:8898/ping 2>/dev/null | grep -q '^pong$'; then
    exit 0
  fi
done
exit 1
EXEC_START
chmod +x "$BRIDGE_DIR/start-exec.sh"

cat > "$PREFIX/bin/codex-start" <<'CODEX_START'
#!/data/data/com.termux/files/usr/bin/bash
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"

if [ -f "$HOME/.bashrc" ]; then
  # 读取用户保存的 OPENAI_API_KEY（没有也不影响后面的报错说明）。
  # shellcheck disable=SC1090
  . "$HOME/.bashrc" >/dev/null 2>&1 || true
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "还没设置密钥，先执行："
  echo "echo 'export OPENAI_API_KEY=sk-你的密钥' >> ~/.bashrc"
  echo "source ~/.bashrc"
  exit 1
fi

"$HOME/codex-bridge/start-exec.sh" || {
  echo "命令服务启动失败，请查看：$HOME/codex-bridge/exec.log"
  exit 1
}

if ! curl -fsS --max-time 1 http://127.0.0.1:8899/v1/models >/dev/null 2>&1; then
  PORT=8899 nohup node "$HOME/codex-bridge/bridge.mjs" > "$HOME/codex-bridge/bridge.log" 2>&1 &
  sleep 2
fi

exec "$PREFIX/bin/codex" --no-daemon "$@"
CODEX_START
chmod +x "$PREFIX/bin/codex-start"

cat > "$HOME_DIR/ask-codex.sh" <<'ASK_CODEX'
#!/data/data/com.termux/files/usr/bin/bash
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"

if [ -f "$HOME/.bashrc" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.bashrc" >/dev/null 2>&1 || true
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "OPENAI_API_KEY 没有设置，请先在 Termux 里配置密钥。"
  exit 1
fi

"$HOME/codex-bridge/start-exec.sh" || {
  echo "命令服务启动失败，请查看：$HOME/codex-bridge/exec.log"
  exit 1
}

if ! curl -fsS --max-time 1 http://127.0.0.1:8899/v1/models >/dev/null 2>&1; then
  PORT=8899 nohup node "$HOME/codex-bridge/bridge.mjs" > "$HOME/codex-bridge/bridge.log" 2>&1 &
  sleep 2
fi

PROMPT="$*"
if [ -z "$PROMPT" ]; then
  echo "问题不能为空。"
  exit 1
fi

exec "$PREFIX/bin/codex" --no-daemon exec --json --skip-git-repo-check \
  --dangerously-bypass-approvals-and-sandbox -C "$HOME" "$PROMPT"
ASK_CODEX
chmod +x "$HOME_DIR/ask-codex.sh"

echo "[4/5] 修正 Codex 桥接端口..."
mkdir -p "$HOME_DIR/.codex"
if [ -f "$HOME_DIR/.codex/config.toml" ]; then
  cp -f "$HOME_DIR/.codex/config.toml" "$HOME_DIR/.codex/config.toml.bak"
fi
cat > "$HOME_DIR/.codex/config.toml" <<'CODEX_CONFIG'
model = "deepseek-flash"
model_provider = "bridge"

[model_providers.bridge]
name = "bridge"
base_url = "http://127.0.0.1:8899/v1"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
CODEX_CONFIG

if ! grep -q 'codex-mobile-exec-autostart' "$HOME_DIR/.bashrc" 2>/dev/null; then
  cat >> "$HOME_DIR/.bashrc" <<'BASHRC_EOF'

# codex-mobile-exec-autostart
if [ -x "$HOME/codex-bridge/start-exec.sh" ]; then
  "$HOME/codex-bridge/start-exec.sh" >/dev/null 2>&1
fi
BASHRC_EOF
fi

echo "[5/5] 启动服务..."
"$BRIDGE_DIR/start-exec.sh" || {
  echo "启动失败，请查看：$BRIDGE_DIR/exec.log"
  exit 1
}

echo
echo "修复完成。"
echo "现在打开 Codex 手机版 App 即可。"
echo "如果手机重启过，只要打开一次 Termux，命令服务会自动启动。"
echo "=========================================="
