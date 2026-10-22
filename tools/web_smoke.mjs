// Drives the Web build in headless Edge/Chrome via the DevTools Protocol.
// Usage: node tools/web_smoke.mjs <steps.json> <out_dir> [profile_dir]
// Steps: {"wait":ms} {"click":[x,y]} {"drag":[x1,y1,x2,y2]} {"type":"text"}
//        {"key":"F9"|"Escape"|"Enter"|"Backspace", "ctrl":bool} {"shot":"name"}
// The profile dir persists IndexedDB (user://) between runs, so a second run
// tests that saves survive a browser restart. Requires tools/serve_web.js running.
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { createServer } from "node:net";

const [stepsFile, outDir, profileArg] = process.argv.slice(2);
if (!stepsFile || !outDir) { console.error("usage: web_smoke.mjs steps.json outdir [profile]"); process.exit(2); }
const steps = JSON.parse(readFileSync(stepsFile, "utf8"));
const profile = resolve(profileArg || join(tmpdir(), "lb_web_profile"));
mkdirSync(outDir, { recursive: true });
const url = process.env.LB_URL || "http://localhost:8060/";
// A free debug port per run (LB_DEBUG_PORT overrides), so concurrent runs by
// different agents can never attach to each other's browser (M4a QA).
const port = Number(process.env.LB_DEBUG_PORT) || await new Promise((res) => {
  const srv = createServer();
  srv.listen(0, "127.0.0.1", () => { const p = srv.address().port; srv.close(() => res(p)); });
});
const browsers = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
];
const exe = process.env.LB_BROWSER || browsers.find(existsSync);
// QA-11: never attach to a browser left over from an earlier run — that would
// silently reuse its profile/page and invalidate "fresh profile" / "restart" checks.
try {
  await fetch(`http://127.0.0.1:${port}/json/version`);
  console.error(`Port ${port} is already in use by another browser. Close it (or run tools/qa_web_smoke.ps1) and retry.`);
  process.exit(3);
} catch { /* port free: good */ }
const proc = spawn(exe, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--window-size=1280,720", "--no-first-run", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "about:blank"],
  { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let ws, nextId = 1;
const pending = new Map();
const logs = [];
function send(method, params = {}) {
  const id = nextId++;
  ws.send(JSON.stringify({ id, method, params }));
  return new Promise((res, rej) => pending.set(id, { res, rej }));
}

try {
  let target;
  for (let i = 0; i < 50 && !target; i++) {
    await sleep(200);
    try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page"); } catch {}
  }
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.rej(new Error(m.error.message)) : p.res(m.result); }
    if (m.method === "Runtime.consoleAPICalled") logs.push(m.params.args.map((a) => a.value ?? a.description).join(" "));
    if (m.method === "Runtime.exceptionThrown") logs.push("EXCEPTION " + m.params.exceptionDetails.text);
  };
  await send("Runtime.enable");
  await send("Page.enable");
  await send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 720, deviceScaleFactor: 1, mobile: false });
  await send("Page.navigate", { url });
  await sleep(6000);
  const mouse = (type, x, y, buttons = 1) => send("Input.dispatchMouseEvent", { type, x, y, button: "left", buttons, clickCount: 1 });
  const keyCodes = { F9: 120, Escape: 27, Enter: 13, Backspace: 8, KeyS: 83 };
  for (const s of steps) {
    if (s.wait) await sleep(s.wait);
    if (s.click) { await mouse("mouseMoved", ...s.click, 0); await mouse("mousePressed", ...s.click); await sleep(80); await mouse("mouseReleased", ...s.click, 0); await sleep(300); }
    if (s.drag) {
      const [x1, y1, x2, y2] = s.drag;
      await mouse("mouseMoved", x1, y1, 0); await mouse("mousePressed", x1, y1); await sleep(80);
      for (let i = 1; i <= 10; i++) { await mouse("mouseMoved", x1 + ((x2 - x1) * i) / 10, y1 + ((y2 - y1) * i) / 10); await sleep(30); }
      await mouse("mouseReleased", x2, y2, 0); await sleep(300);
    }
    if (s.type) {
      // Godot's web build reads real key events, so type char by char.
      for (const ch of s.type) {
        const vk = ch.toUpperCase().charCodeAt(0);
        const code = /[0-9]/.test(ch) ? "Digit" + ch : "Key" + ch.toUpperCase();
        await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch, code, windowsVirtualKeyCode: vk });
        await send("Input.dispatchKeyEvent", { type: "keyUp", key: ch, code, windowsVirtualKeyCode: vk });
        await sleep(40);
      }
      await sleep(200);
    }
    if (s.key) {
      const code = s.key.length === 1 ? s.key.toUpperCase().charCodeAt(0) : keyCodes[s.key];
      const base = { key: s.key, code: s.key.length === 1 ? "Key" + s.key.toUpperCase() : s.key, windowsVirtualKeyCode: code, modifiers: s.ctrl ? 2 : 0 };
      await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...base }); await sleep(60);
      await send("Input.dispatchKeyEvent", { type: "keyUp", ...base }); await sleep(300);
    }
    if (s.shot) {
      const { data } = await send("Page.captureScreenshot", { format: "png" });
      writeFileSync(join(outDir, s.shot + ".png"), Buffer.from(data, "base64"));
      console.log("shot", s.shot);
    }
  }
  writeFileSync(join(outDir, "console.log"), logs.join("\n"));
  console.log("console lines:", logs.length, "| errors:", logs.filter((l) => /error|exception/i.test(l)).length);
} finally {
  try { ws?.close(); } catch {}
  // proc.kill() leaves Edge's child processes alive on Windows (QA-11). Edge also
  // re-parents helpers outside the tree, so kill the tree AND every process
  // using this run's profile, then wait until the debug port is really free.
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/PID", String(proc.pid), "/T", "/F"], { stdio: "ignore" });
    const ps = `Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" | ` +
      `Where-Object { $_.CommandLine -like '*${profile.replace(/'/g, "''")}*' } | ` +
      `ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`;
    spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", ps], { stdio: "ignore" });
  } else proc.kill();
  for (let i = 0; i < 25; i++) {
    try { await fetch(`http://127.0.0.1:${port}/json/version`); await sleep(200); } catch { break; }
  }
}
