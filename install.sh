#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# 手机版 Codex 一键安装（在 Termux 里运行）
# 装什么：
#   1. 真正的 Codex CLI（官方 ARM64 版本）
#   2. 一个接口桥接（Codex 只说 responses，DeepSeek 只说 chat，中间要翻译）
#   3. Codex 的配置，指向本地桥接
# 装完之后手机就能独立跑 Codex，只要有网，不需要电脑。
# ============================================================
set -e

TOTAL=6
echo "=========================================="
echo "         手机版 Codex 安装程序"
echo "         （共 $TOTAL 步，每步都会显示进度）"
echo "=========================================="
echo

echo "[1/$TOTAL] 更新软件源索引"
echo "      这一步可能要等十几秒到一分钟，属正常"
pkg update -y || true
echo "      ✓ 完成"
echo

echo "[2/$TOTAL] 安装依赖：Node、curl、tar"
echo "      ↓ 这一步要下载几十 MB，下面的进度条是在正常干活，别关掉就行"
pkg install -y nodejs-lts curl tar || pkg install -y nodejs curl tar
echo "      ✓ 依赖装好了"
echo

echo "[3/$TOTAL] 下载 Codex（按手机架构自动选版本）"
cd "$HOME"
ARCH="$(uname -m)"
if [ "$ARCH" = "aarch64" ]; then
  TARGET="aarch64-unknown-linux-musl"
else
  TARGET="x86_64-unknown-linux-musl"
fi
echo "      手机架构: $ARCH  ->  下载: $TARGET"
echo "      ↓ 这个包约 80MB，进度条在下面"
URL="https://github.com/openai/codex/releases/latest/download/codex-${TARGET}.tar.gz"
rm -rf "$HOME/codex-dl"
mkdir -p "$HOME/codex-dl"
if ! curl -L --fail --progress-bar -o "$HOME/codex-dl/pkg.tar.gz" "$URL"; then
  echo "      !! 下载失败。请检查网络（国内可能需要加速），然后重跑本脚本。"
  exit 1
fi
echo "      正在解压..."
tar xzf "$HOME/codex-dl/pkg.tar.gz" -C "$HOME/codex-dl"
BIN="$(find "$HOME/codex-dl" -type f -name 'codex' | head -n 1)"
if [ -z "$BIN" ]; then
  BIN="$(find "$HOME/codex-dl" -type f -name "codex-${TARGET}" | head -n 1)"
fi
if [ -z "$BIN" ]; then
  echo "      !! 压缩包里没找到 codex 可执行文件。"
  echo "      文件列表如下，请把这几行发给助手："
  find "$HOME/codex-dl" -type f | head -20
  exit 1
fi
chmod +x "$BIN"
mkdir -p "$PREFIX/bin"
cp -f "$BIN" "$PREFIX/bin/codex"
chmod +x "$PREFIX/bin/codex"
rm -rf "$HOME/codex-dl"
echo "      ✓ codex 已安装到 $PREFIX/bin/codex"
echo

echo "[4/$TOTAL] 安装接口桥接"
mkdir -p "$HOME/codex-bridge"
cat > "$HOME/codex-bridge/bridge.mjs" <<'BRIDGE_EOF'
// Codex <-> DeepSeek 桥接
// Codex CLI 只说 Responses API，DeepSeek 只说 Chat Completions，
// 这个小服务夹在中间做翻译，让手机上的 Codex 能直连 DeepSeek。
import http from "node:http";

const UPSTREAM = (process.env.UPSTREAM || "https://api.deepseek.com").replace(/\/+$/, "");
const API_KEY = process.env.API_KEY || process.env.OPENAI_API_KEY || "";
const PORT = Number(process.env.PORT || 8899);

// DeepSeek 的 thinking 模式要求：上一轮 assistant 的 reasoning_content 必须原样传回。
// Codex 的接口格式里没有这个概念，所以这里缓存一下，下一轮自动补上。
const reasoningCache = new Map();
let lastReasoning = "";

function cacheReasoning(msg) {
  const rc = msg && msg.reasoning_content;
  if (!rc) return;
  lastReasoning = rc;
  for (const tc of msg.tool_calls || []) {
    if (tc && tc.id) reasoningCache.set("call:" + tc.id, rc);
  }
  if (msg.content) reasoningCache.set("text:" + String(msg.content).slice(0, 200), rc);
  if (reasoningCache.size > 200) {
    const first = reasoningCache.keys().next().value;
    reasoningCache.delete(first);
  }
}

function lookupReasoning(toolCalls, content) {
  for (const tc of toolCalls || []) {
    if (tc && tc.id) {
      const hit = reasoningCache.get("call:" + tc.id);
      if (hit) return hit;
    }
  }
  if (content) {
    const hit = reasoningCache.get("text:" + String(content).slice(0, 200));
    if (hit) return hit;
  }
  return null;
}

function id(prefix) {
  return prefix + "_" + Math.random().toString(36).slice(2) + Date.now().toString(36);
}

// ---------- 请求：Responses -> Chat ----------
function toChat(body) {
  const messages = [];
  if (body.instructions) messages.push({ role: "system", content: String(body.instructions) });

  const input = Array.isArray(body.input) ? body.input : [];
  for (const item of input) {
    if (!item || typeof item !== "object") continue;
    if (item.type === "message" || item.role) {
      let text = "";
      if (typeof item.content === "string") {
        text = item.content;
      } else if (Array.isArray(item.content)) {
        text = item.content
          .map((c) => (typeof c === "string" ? c : c && (c.text || c.content || "")))
          .join("");
      }
      // DeepSeek 不认 OpenAI 新出的 developer 角色，统一换成 system
      let role = item.role || "user";
      if (role === "developer") role = "system";
      if (role !== "system" && role !== "user" && role !== "assistant" && role !== "tool") role = "user";
      if (text) {
        const m = { role: role, content: text };
        // thinking 模式下，历史里的 assistant 消息也必须带回 reasoning_content
        if (role === "assistant") {
          const rc2 = lookupReasoning(null, text) || lastReasoning;
          if (rc2) m.reasoning_content = rc2;
        }
        messages.push(m);
      }
    } else if (item.type === "function_call") {
      const callId = item.call_id || id("call");
      const assistantMsg = {
        role: "assistant",
        content: null,
        tool_calls: [{
          id: callId,
          type: "function",
          function: { name: item.name, arguments: item.arguments || "{}" },
        }],
      };
      const rc = lookupReasoning(assistantMsg.tool_calls, null) || lastReasoning;
      if (rc) assistantMsg.reasoning_content = rc;
      messages.push(assistantMsg);
    } else if (item.type === "function_call_output") {
      messages.push({
        role: "tool",
        tool_call_id: item.call_id || "",
        content: typeof item.output === "string" ? item.output : JSON.stringify(item.output || ""),
      });
    }
  }

  const tools = [];
  for (const t of body.tools || []) {
    if (!t) continue;
    if (t.type === "function") {
      tools.push({
        type: "function",
        function: {
          name: t.name,
          description: t.description || "",
          parameters: t.parameters || { type: "object", properties: {} },
        },
      });
    } else if (t.function) {
      tools.push(t);
    }
  }

  const out = { model: body.model, messages, stream: false };
  if (tools.length) out.tools = tools;
  if (body.max_output_tokens) out.max_tokens = body.max_output_tokens;
  if (typeof body.temperature === "number") out.temperature = body.temperature;
  return out;
}

// ---------- 响应：Chat -> Responses ----------
function toResponses(chat, model) {
  const choice = (chat.choices && chat.choices[0]) || {};
  const msg = choice.message || {};
  cacheReasoning(msg);
  const output = [];

  if (msg.content) {
    output.push({
      type: "message",
      id: id("msg"),
      role: "assistant",
      status: "completed",
      content: [{ type: "output_text", text: String(msg.content), annotations: [] }],
    });
  }
  for (const tc of msg.tool_calls || []) {
    output.push({
      type: "function_call",
      id: id("fc"),
      call_id: tc.id || id("call"),
      name: tc.function ? tc.function.name : "",
      arguments: (tc.function && tc.function.arguments) || "{}",
      status: "completed",
    });
  }
  if (!output.length) {
    output.push({
      type: "message",
      id: id("msg"),
      role: "assistant",
      status: "completed",
      content: [{ type: "output_text", text: "", annotations: [] }],
    });
  }

  const u = chat.usage || {};
  return {
    id: id("resp"),
    object: "response",
    created_at: Math.floor(Date.now() / 1000),
    status: "completed",
    model: model || chat.model || "",
    output,
    output_text: msg.content ? String(msg.content) : "",
    usage: {
      input_tokens: u.prompt_tokens || 0,
      output_tokens: u.completion_tokens || 0,
      total_tokens: u.total_tokens || 0,
    },
  };
}

function sendEvent(res, type, payload) {
  res.write("event: " + type + "\n");
  res.write("data: " + JSON.stringify(Object.assign({ type }, payload)) + "\n\n");
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method === "GET" && req.url.startsWith("/v1/models")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ object: "list", data: [
        { id: "deepseek-flash", object: "model", owned_by: "deepseek" },
        { id: "deepseek-v4-pro", object: "model", owned_by: "deepseek" },
      ] }));
      return;
    }

    if (req.method === "POST" && req.url.indexOf("/responses") >= 0) {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      let body = {};
      try { body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}"); } catch (e) { body = {}; }

      const chatBody = toChat(body);
      const up = await fetch(UPSTREAM + "/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + API_KEY },
        body: JSON.stringify(chatBody),
      });
      const text = await up.text();
      if (up.status !== 200) {
        res.writeHead(up.status, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: text.slice(0, 800), type: "upstream_error" } }));
        return;
      }

      let chat;
      try { chat = JSON.parse(text); } catch (e) {
        res.writeHead(502, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: "upstream not json" } }));
        return;
      }

      const response = toResponses(chat, body.model);

      if (body.stream) {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });
        sendEvent(res, "response.created", { response });
        sendEvent(res, "response.in_progress", { response });
        for (let i = 0; i < response.output.length; i++) {
          const item = response.output[i];
          sendEvent(res, "response.output_item.added", { output_index: i, item });
          if (item.type === "message") {
            for (let k = 0; k < item.content.length; k++) {
              const piece = item.content[k];
              sendEvent(res, "response.content_part.added", {
                item_id: item.id, output_index: i, content_index: k, part: piece,
              });
              sendEvent(res, "response.output_text.delta", {
                item_id: item.id, output_index: i, content_index: k, delta: piece.text || "",
              });
              sendEvent(res, "response.output_text.done", {
                item_id: item.id, output_index: i, content_index: k, text: piece.text || "",
              });
              sendEvent(res, "response.content_part.done", {
                item_id: item.id, output_index: i, content_index: k, part: piece,
              });
            }
          }
          sendEvent(res, "response.output_item.done", { output_index: i, item });
        }
        sendEvent(res, "response.completed", { response });
        res.end();
        return;
      }

      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(response));
      return;
    }

    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: { message: "not found" } }));
  } catch (err) {
    try {
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: { message: String((err && err.message) || err) } }));
      } else {
        res.end();
      }
    } catch (e) { }
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log("桥接已启动: http://127.0.0.1:" + PORT + "/v1");
  console.log("上游: " + UPSTREAM + "   密钥: " + (API_KEY ? "已设置" : "缺失"));
});
BRIDGE_EOF
echo "      ✓ 桥接装好了"
echo

echo "[5/$TOTAL] 写 Codex 配置"
mkdir -p "$HOME/.codex"
cat > "$HOME/.codex/config.toml" <<'CFG_EOF'
model = "deepseek-flash"
model_provider = "bridge"

[model_providers.bridge]
name = "bridge"
base_url = "http://127.0.0.1:8899/v1"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
CFG_EOF
echo "      ✓ 配置写好了"
echo

echo "[6/$TOTAL] 创建快捷启动命令"
mkdir -p "$PREFIX/bin"
cat > "$PREFIX/bin/codex-start" <<'START_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# 一步启动：桥接 + Codex
if [ -z "$OPENAI_API_KEY" ]; then
  echo "!! 还没设置密钥，先执行："
  echo "   export OPENAI_API_KEY=sk-你的密钥"
  exit 1
fi
if ! pgrep -f "bridge.mjs" >/dev/null 2>&1; then
  nohup node "$HOME/codex-bridge/bridge.mjs" > "$HOME/codex-bridge/bridge.log" 2>&1 &
  sleep 1
fi
codex "$@"
START_EOF
chmod +x "$PREFIX/bin/codex-start"
echo "      ✓ 完成"
echo

echo "=========================================="
echo "     全部 $TOTAL 步都完成了 ✓"
echo "=========================================="
echo
echo "还差一步：设置你的 DeepSeek 密钥"
echo
echo "  执行这两行（把 sk-xxx 换成你自己的新密钥）："
echo
echo "    sed -i '/OPENAI_API_KEY/d' ~/.bashrc"
echo "    echo 'export OPENAI_API_KEY=sk-你的密钥' >> ~/.bashrc"
echo "    source ~/.bashrc"
echo
echo "然后以后每次只要输入："
echo
echo "    codex-start"
echo
echo "就会自动启动桥接并打开 Codex。"
echo "=========================================="
