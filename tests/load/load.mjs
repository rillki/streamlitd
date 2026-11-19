// Load test: many simultaneous sessions against tests/load/app (Node 22's built-in WebSocket).
// Checks that every session gets its own results (no cross-talk), that a slow blocking call in one
// session does not hold up the others, that a cached computation runs once for everybody, and that
// refreshFragments reaches every session. Prints the numbers; exits 1 on a failure.
//   node tests/load/load.mjs [--sessions 50] [--threads 2]
import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (name, def) => { const i = process.argv.indexOf("--" + name); return i > 0 ? +process.argv[i + 1] : def; };
const N = arg("sessions", 50), THREADS = arg("threads", 2), PORT = arg("port", 8799);
const base = `127.0.0.1:${PORT}`;
const failures = [];
const fail = (msg) => { failures.push(msg); console.log("  ✘ " + msg); };
const ok = (msg) => console.log("  ✓ " + msg);
const pct = (xs, p) => { const s = xs.slice().sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]; };

// one browser tab, speaking the streamlitd protocol
class Client {
  constructor(i) { this.i = i; this.ids = {}; this.texts = []; this.waiters = []; this.finished = 0; }
  open() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`ws://${base}/_stcore/ws`);
      this.ws.onerror = (e) => reject(new Error("websocket error " + (e.message || "")));
      this.ws.onopen = () => { this.send({ type: "rerun", updates: {}, page: "" }); this.until(() => this.finished >= 1).then(resolve, reject); };
      this.ws.onmessage = (ev) => this.onMessage(JSON.parse(ev.data));
    });
  }
  onMessage(m) {
    if (m.type === "delta" && m.el) {
      if (m.el.id && m.el.label) this.ids[m.el.label] = m.el.id;
      if (m.el.kind === "text") this.texts.push(m.el.body);
    } else if (m.type === "script_finished" && m.status !== "rerun") this.finished++;
    for (const w of this.waiters.slice()) if (w.cond()) { this.waiters.splice(this.waiters.indexOf(w), 1); w.resolve(); }
  }
  send(m) { this.ws.send(JSON.stringify(m)); }
  until(cond, ms = 20000) {
    if (cond()) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const w = { cond, resolve };
      this.waiters.push(w);
      setTimeout(() => { const k = this.waiters.indexOf(w); if (k >= 0) { this.waiters.splice(k, 1); reject(new Error("timeout in session " + this.i)); } }, ms);
    });
  }
  /** Run with widget updates or a button click; resolves with the milliseconds it took. */
  async run(msg) {
    const n = this.finished, t0 = performance.now();
    this.texts = [];
    this.send(Object.assign({ type: "rerun", updates: {}, page: "" }, msg));
    await this.until(() => this.finished > n);
    return performance.now() - t0;
  }
  click(label) { return this.run({ trigger: this.ids[label], triggerValue: true }); }
  close() { this.ws.close(); }
}

async function main() {
  const bin = path.join(here, "loadapp");
  const server = spawn(bin, ["--port", String(PORT), "--host", "127.0.0.1", "--quiet", "--script-threads", String(THREADS)], { stdio: ["ignore", "inherit", "inherit"] });
  try {
    for (let k = 0; k < 100; k++) {
      try { if ((await fetch(`http://${base}/_stcore/health`)).ok) break; } catch (e) {}
      await sleep(100);
    }
    console.log(`load test: ${N} sessions, ${THREADS} script threads`);
    const clients = Array.from({ length: N }, (_, i) => new Client(i));
    let t0 = performance.now();
    await Promise.all(clients.map((c) => c.open()));
    ok(`${N} sessions connected and ran in ${Math.round(performance.now() - t0)} ms`);

    // 1. every session types its own name and clicks Echo at the same time: it must see only its own
    await Promise.all(clients.map((c) => c.run({ updates: { [c.ids["Name"]]: "user-" + c.i } })));
    const lat = await Promise.all(clients.map((c) => c.click("Echo")));
    const wrong = clients.filter((c) => !c.texts.includes("echo:user-" + c.i) || c.texts.some((t) => t.startsWith("echo:") && t !== "echo:user-" + c.i));
    if (wrong.length) fail(`${wrong.length} sessions saw another session's value (e.g. ${JSON.stringify(wrong[0].texts)})`);
    else ok(`no cross-talk: each of ${N} sessions saw only its own value`);
    console.log(`    run latency: p50 ${Math.round(pct(lat, 50))} ms, p95 ${Math.round(pct(lat, 95))} ms, max ${Math.round(Math.max(...lat))} ms`);

    // 2. one session runs a 1.5 s blocking call; the others keep working meanwhile
    const slow = clients[0].click("Slow");
    await sleep(100);
    t0 = performance.now();
    const during = await Promise.all(clients.slice(1).map((c) => c.click("Echo")));
    const others = performance.now() - t0;
    const slowMs = await slow;
    if (!clients[0].texts.includes("slow:done")) fail("the slow run did not finish");
    if (others > 1200) fail(`the other sessions waited for the blocking call (${Math.round(others)} ms)`);
    else ok(`while one session blocked for ${Math.round(slowMs)} ms, ${N - 1} others finished their runs in ${Math.round(others)} ms (p95 ${Math.round(pct(during, 95))} ms)`);

    // 3. all sessions ask for the same uncached slow value at once: it is computed once
    await Promise.all(clients.map((c) => c.click("Cached")));
    const counts = new Set(clients.map((c) => (c.texts.find((t) => t.startsWith("cached:")) || "").replace(/^cached:49 computed:/, "")));
    if (counts.size !== 1 || !counts.has("1")) fail(`the cached value was computed ${[...counts].join("/")} times`);
    else ok(`cacheData: ${N} simultaneous first calls, computed once`);

    // 4. one push reaches every session's fragment
    const before = clients.map((c) => c.finished);
    await clients[1].click("Push");
    await Promise.all(clients.map((c, k) => c.until(() => c.texts.includes("pushed:1") || c.finished > before[k] + (k === 1 ? 1 : 0) && c.texts.includes("pushed:1"), 5000).catch(() => {})));
    const missed = clients.filter((c) => !c.texts.includes("pushed:1"));
    if (missed.length) fail(`${missed.length} sessions did not get the pushed fragment update`);
    else ok(`refreshFragments reached all ${N} sessions`);

    clients.forEach((c) => c.close());
    await sleep(500); // let the server see the sockets close
  } finally {
    server.kill("SIGINT");
    await new Promise((r) => { server.on("exit", r); setTimeout(r, 3000); });
  }
  if (failures.length) { console.log(`load test FAILED (${failures.length})`); process.exit(1); }
  console.log("load test OK");
}

main().catch((e) => { console.error("load test error:", e.message); process.exit(1); });
