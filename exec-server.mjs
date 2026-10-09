// Codex 手机版 <-> Termux 命令执行服务
// App 通过 HTTP 让 Termux 跑命令，比 RUN_COMMAND 稳定得多：
// 不用外部应用权限、不依赖 Termux 会话状态。
import http from "node:http";
import { exec } from "node:child_process";

const PORT = Number(process.env.EXEC_PORT || 8898);

http.createServer((req, res) => {
  // 健康检查
  if (req.method === "GET" && req.url === "/ping") {
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("pong");
    return;
  }
  if (req.method !== "POST") {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
    return;
  }

  let body = "";
  req.on("data", (c) => {
    body += c;
    if (body.length > 8 * 1024 * 1024) req.destroy();
  });
  req.on("end", () => {
    let cmd = "";
    try {
      cmd = (JSON.parse(body) || {}).cmd || "";
    } catch (e) { }
    if (!cmd) {
      res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("no cmd");
      return;
    }
    exec(cmd, {
      cwd: process.env.HOME,
      timeout: 150000,
      maxBuffer: 8 * 1024 * 1024,
      shell: "/data/data/com.termux/files/usr/bin/bash",
    }, (err, stdout, stderr) => {
      let out = String(stdout || "") + String(stderr || "");
      if (!out) out = err ? ("(退出码 " + err.code + ")") : "(没有输出)";
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(out);
    });
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log("命令执行服务已启动: http://127.0.0.1:" + PORT);
});