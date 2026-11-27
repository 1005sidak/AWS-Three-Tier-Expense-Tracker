// Load generator for the auto-scaling demo. Needs only Node.js (no packages).
// Usage (from your laptop):
//   node loadtest.js http://<public-alb-dns> [concurrency=30] [minutes=10]
// It repeatedly calls /api/compute, which burns CPU on the app servers,
// so CloudWatch CPU rises and the Auto Scaling group launches extra instances.
const http = require("http");

const base = process.argv[2];
if (!base) {
  console.log("Usage: node loadtest.js http://<public-alb-dns> [concurrency] [minutes]");
  process.exit(1);
}
const concurrency = Number(process.argv[3] || 30);
const minutes = Number(process.argv[4] || 10);
const url = new URL("/api/compute?ms=200", base);
const stopAt = Date.now() + minutes * 60 * 1000;
const agent = new http.Agent({ keepAlive: true, maxSockets: concurrency });

let ok = 0, failed = 0;
const servers = new Map();

function hit() {
  if (Date.now() > stopAt) return;
  http.get(url, { agent }, (res) => {
    let body = "";
    res.on("data", (c) => (body += c));
    res.on("end", () => {
      if (res.statusCode === 200) {
        ok++;
        try {
          const s = JSON.parse(body).server;
          servers.set(s, (servers.get(s) || 0) + 1);
        } catch {}
      } else failed++;
      hit();
    });
  }).on("error", () => { failed++; setTimeout(hit, 500); });
}

console.log(`Sending load to ${url} with ${concurrency} parallel requests for ${minutes} min...`);
for (let i = 0; i < concurrency; i++) hit();

const timer = setInterval(() => {
  const list = [...servers.entries()].map(([s, n]) => `${s}: ${n}`).join(" | ");
  console.log(`[${new Date().toLocaleTimeString()}] ok=${ok} failed=${failed} | app servers -> ${list}`);
  if (Date.now() > stopAt) { clearInterval(timer); console.log("Done."); process.exit(0); }
}, 10000);
