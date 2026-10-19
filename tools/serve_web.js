// Minimal static server for the Web smoke build (no dependencies).
// Usage: node tools/serve_web.js [port]   -> http://localhost:8060
// Sends COOP/COEP headers so a future threaded export also works.
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..", "build", "web");
const port = Number(process.argv[2]) || 8060;
const types = {
  ".html": "text/html", ".js": "application/javascript", ".wasm": "application/wasm",
  ".pck": "application/octet-stream", ".png": "image/png", ".svg": "image/svg+xml",
  ".json": "application/json", ".ico": "image/x-icon",
};

http.createServer((req, res) => {
  const urlPath = decodeURIComponent(req.url.split("?")[0]);
  const file = path.normalize(path.join(root, urlPath === "/" ? "index.html" : urlPath));
  if (!file.startsWith(root)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end("not found"); }
    res.writeHead(200, {
      "Content-Type": types[path.extname(file)] || "application/octet-stream",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    });
    res.end(data);
  });
}).listen(port, "127.0.0.1", () => console.log(`Serving ${root} at http://localhost:${port}`));
