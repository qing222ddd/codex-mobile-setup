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
