// Regenerates the screenshots in docs/images/ (used by README.md and docs/).
//   cd tests/e2e && node screenshots.js        (examples must be built: ../../run-tests.sh does that)
// Then: python3 ../../tools/optimize_images.py
const { chromium } = require("playwright");
const { spawn } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");

const root = path.resolve(__dirname, "../..");
const out = path.join(root, "docs/images");
fs.mkdirSync(out, { recursive: true });

const apps = { hello: 8801, widgets: 8802, data: 8803, multipage: 8804, themes: 8805, fragments: 8807, extras: 8808, auth: 8809, tutorial: 8810 };
const procs = [];
let browser = null;

// the larger examples, each with fresh demo data and a fixed "today" (docs/examples.md)
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "streamlitd-shots-"));
const bigApps = {
  helpdesk: [8818, { HELPDESK_DATA: tmp + "/helpdesk.json", STREAMLITD_AUTH_USERS_FILE: tmp + "/hd-users.json" }],
  planning: [8819, { PLANNING_DATA: tmp + "/planning.json", PLANNING_TODAY: "2026-11-18" }],
  monitor: [8820, { MONITOR_TICK_MS: "300", MONITOR_SLOW_MS: "300" }],
  todo: [8821, { TODO_DATA: tmp + "/todo.json", TODO_TODAY: "2026-11-18", STREAMLITD_AUTH_USERS_FILE: tmp + "/todo-users.json" }],
  gantt: [8822, { GANTT_DATA: tmp + "/gantt.json", GANTT_TODAY: "2026-11-18" }],
  // more examples for examples/README.md
  accounts: [8823, { STREAMLITD_AUTH_USERS_FILE: tmp + "/acc-users.json" }],
  api: [8824, {}],
  custom: [8825, {}],
  business: [8826, {}],
  prod: [8827, {}],
};
const bigBase = { prod: "/app" };

function start(name, port, env = {}) {
  const p = spawn(`./${name}`, ["--port", String(port), "--host", "127.0.0.1", "--quiet"],
    { cwd: path.join(root, "examples", name), stdio: "ignore", env: Object.assign({}, process.env, env) });
  procs.push(p);
}
async function waitHealth(port, base = "") {
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}${base}/_stcore/health`); if (r.ok) return; } catch (e) {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("server on port " + port + " did not start");
}
function chromePath() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const cache = path.join(os.homedir(), ".cache/ms-playwright");
  for (const d of fs.readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse()) {
    const p = path.join(cache, d, "chrome-linux64/chrome");
    if (fs.existsSync(p)) return p;
  }
  return undefined;
}

const only = process.env.ONLY; // ONLY=tutorial | data | themes | examples regenerates a subset

(async () => {
  for (const [n, p] of Object.entries(apps)) start(n, p);
  for (const p of Object.values(apps)) await waitHealth(p);
  if (!only || only === "examples") {
    for (const [n, [p, env]] of Object.entries(bigApps)) { start(n, p, env); apps[n] = p; }
    for (const [n, [p]] of Object.entries(bigApps)) await waitHealth(p, bigBase[n] || "");
  }
  browser = await chromium.launch({ executablePath: chromePath() });

  async function page(app, urlPath = "/", opts = {}) {
    const ctx = await browser.newContext({ viewport: { width: opts.width || 1280, height: opts.height || 800 }, deviceScaleFactor: 1 });
    if (opts.appearance) {
      await ctx.addInitScript((a) => localStorage.setItem("streamlitd-appearance", JSON.stringify(a)), opts.appearance);
    }
    const pg = await ctx.newPage();
    await pg.goto(`http://127.0.0.1:${apps[app]}${urlPath}`);
    await pg.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1 && document.body.dataset.running === "0");
    return pg;
  }
  const idle = (pg) => pg.waitForFunction(() => document.body.dataset.running === "0");
  async function rerun(pg, action) {
    const before = await pg.evaluate(() => +document.body.dataset.runs);
    await action();
    await pg.waitForFunction((b) => +document.body.dataset.runs > b && document.body.dataset.running === "0", before);
  }
  async function shot(pg, name, opts = {}) {
    await pg.waitForTimeout(opts.wait || 600);
    await pg.screenshot({ path: path.join(out, name + ".png"), fullPage: !!opts.fullPage, clip: opts.clip });
    console.log("  " + name + ".png");
    await pg.context().close();
  }
  // viewer appearance stored in localStorage; basis = the app's scheme/design/mode it applies to
  const look = (scheme, design, mode) => ({ scheme, design, mode, basis: "streamlit/streamlit/auto" });
  const dark = (scheme = "streamlit") => look(scheme, "streamlit", "dark");

  let p;
  if (only === "tutorial") return tutorialShots();
  if (only === "data") return dataShots();
  if (only === "themes") return themeShots();
  if (only === "examples") return exampleShots();
  // hello
  p = await page("hello");
  await rerun(p, async () => { await p.getByLabel("Your name").fill("Kirill"); await p.getByLabel("Your name").press("Enter"); });
  await rerun(p, () => p.getByRole("button", { name: "Greet" }).click());
  await shot(p, "hello");

  // widgets
  p = await page("widgets", "/", { height: 1150 });
  await shot(p, "widgets");
  p = await page("widgets");
  await p.getByRole("tab", { name: "Layout" }).click();
  await p.getByText("Click to expand").click();
  await shot(p, "layout");
  p = await page("widgets");
  await p.getByRole("tab", { name: "Forms" }).click();
  await p.getByLabel("Email").fill("ann@example.com");
  await p.getByLabel("Plan").click();
  await p.locator("#stPopups .st-option", { hasText: /^Pro$/ }).click();
  await rerun(p, () => p.getByRole("button", { name: "Sign up" }).click());
  await shot(p, "forms");
  p = await page("widgets");
  await p.getByRole("tab", { name: "Status" }).click();
  await rerun(p, () => p.getByRole("button", { name: "Run long task" }).click());
  await rerun(p, () => p.getByRole("button", { name: "Toast me" }).click());
  await shot(p, "status");

  await dataShots();
  async function dataShots() {
  p = await page("data", "/", { height: 900 });
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "dataframe", { wait: 1200 });
  p = await page("data", "/", { height: 900 });
  await p.evaluate(() => window.scrollTo(0, document.querySelector("h3#charts").getBoundingClientRect().top + window.scrollY - 70));
  await p.waitForFunction(() => document.querySelectorAll("[data-testid=st-vega-lite][data-rendered]").length >= 5);
  await shot(p, "charts", { wait: 1500 });
  p = await page("data", "/", { height: 700 });
  await p.waitForFunction(() => document.querySelectorAll("[data-testid=st-vega-lite][data-rendered]").length >= 5);
  await p.waitForTimeout(800);
  await p.evaluate(() => {
    const hd = Array.from(document.querySelectorAll("h3")).find((x) => x.textContent.startsWith("st.data_editor"));
    window.scrollTo(0, hd.getBoundingClientRect().top + window.scrollY - 70);
  });
  await shot(p, "data-editor");
  }
  if (only) return;

  // multipage chat, dark
  p = await page("multipage", "/chat", { appearance: dark() });
  const ta = p.getByTestId("st-chat-input").locator("textarea");
  await rerun(p, async () => { await ta.fill("Hi there!"); await ta.press("Enter"); });
  await rerun(p, async () => { await ta.fill("What can streamlitd do?"); await ta.press("Enter"); });
  await shot(p, "chat-dark");

  // fragments + dialog
  p = await page("fragments", "/", { height: 860 });
  await rerun(p, () => p.getByRole("button", { name: "Edit profile" }).click());
  await shot(p, "dialog");
  p = await page("fragments", "/", { height: 1500 });
  await rerun(p, () => p.getByRole("button", { name: "Run job" }).click());
  await rerun(p, () => p.getByRole("button", { name: "L", exact: true }).click());
  await rerun(p, () => p.getByRole("button", { name: "stars 4" }).click());
  await shot(p, "fragments");

  // extras
  p = await page("extras");
  await p.waitForSelector(".katex");
  await p.waitForSelector("code.hljs");
  await shot(p, "math-code", { wait: 1000 });
  // themed controls: calendar open in the design gallery
  p = await page("themes", "/", { height: 760 });
  await p.locator("#stRoot-0").getByRole("button", { name: "Open calendar" }).scrollIntoViewIfNeeded();
  await p.locator("#stRoot-0").getByRole("button", { name: "Open calendar" }).click();
  await shot(p, "controls", { wait: 500 });
  p = await page("extras");
  await p.getByRole("tab", { name: "Plotly" }).click();
  await p.waitForSelector("[data-testid=st-plotly][data-rendered]");
  await shot(p, "plotly", { wait: 1200 });
  p = await page("extras");
  await p.getByRole("tab", { name: "Map" }).click();
  await p.waitForSelector("[data-testid=st-map][data-rendered]");
  await shot(p, "map", { wait: 3500 });

  await themeShots();
  async function themeShots() {
  // design styles (streamlit scheme) and color schemes (streamlit design), light + dark;
  // tools/optimize_images.py builds the contact sheets
  const designs = ["streamlit", "terminal", "retro", "win95", "xp", "brutalist", "material", "glass"];
  const schemes = ["streamlit", "minimal", "ocean", "forest", "sunset", "finance", "solarized", "paper"];
  for (const design of designs) for (const mode of ["light", "dark"]) {
    p = await page("themes", "/", { appearance: look("streamlit", design, mode) });
    await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
    await shot(p, `design-${design}-${mode}`, { wait: 900 });
  }
  for (const scheme of schemes) for (const mode of ["light", "dark"]) {
    p = await page("themes", "/", { appearance: look(scheme, "streamlit", mode) });
    await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
    await shot(p, `scheme-${scheme}-${mode}`, { wait: 900 });
  }
  // a few design × scheme combinations, full page with the dialog open
  const combos = [["terminal", "solarized", "dark"], ["xp", "ocean", "light"], ["win95", "paper", "light"], ["retro", "sunset", "dark"],
    ["brutalist", "minimal", "light"], ["glass", "finance", "dark"], ["material", "forest", "light"]];
  for (const [design, scheme, mode] of combos) {
    p = await page("themes", "/", { appearance: look(scheme, design, mode), height: 900 });
    await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
    await rerun(p, () => p.getByRole("button", { name: "Open dialog" }).click());
    await shot(p, `combo-${design}-${scheme}-${mode}`, { wait: 900 });
  }
  }
  if (only === "themes") return;

  // login page
  p = await (async () => {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const pg = await ctx.newPage();
    await pg.goto(`http://127.0.0.1:${apps.auth}/`);
    await pg.waitForSelector("h1");
    return pg;
  })();
  await shot(p, "login");

  await tutorialShots();
  await exampleShots();

  // the larger examples (docs/examples.md)
  async function exampleShots() {
  const ready = (pg) => pg.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1 && document.body.dataset.running === "0");
  // helpdesk: sign in on the login page first
  let ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1 });
  p = await ctx.newPage();
  await p.goto(`http://127.0.0.1:${apps.helpdesk}/tickets`);
  await p.getByLabel("Username").fill("alice");
  await p.getByLabel("Password").fill("streamlitd-demo");
  await p.getByRole("button", { name: "Sign in" }).click();
  await p.waitForURL(/tickets/);
  await ready(p);
  await rerun(p, () => p.getByTestId("st-dataframe").locator("tbody tr").nth(1).locator("td").first().click());
  await shot(p, "example-helpdesk", { wait: 800 });

  p = await page("planning", "/plan-vs-fact", { height: 860 });
  await p.getByTestId("st-dataframe").getByRole("button", { name: "Expand ACME" }).click();
  await rerun(p, () => p.getByTestId("st-dataframe").locator("tr", { hasText: "Rocket" }).click());
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "example-planning", { wait: 1000 });

  p = await page("planning", "/deliveries", { height: 860 });
  await shot(p, "example-deliveries", { wait: 800 });

  // todo: sign up a user
  ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1 });
  p = await ctx.newPage();
  await p.goto(`http://127.0.0.1:${apps.todo}/auth/register`);
  await p.getByLabel("Username").fill("ann");
  await p.getByLabel("Password", { exact: true }).fill("streamlitd-demo");
  await p.getByLabel("Repeat the password").fill("streamlitd-demo");
  await p.getByRole("button", { name: "Create account" }).click();
  await p.waitForURL((u) => !u.pathname.startsWith("/auth/"));
  await ready(p);
  await shot(p, "example-todo", { wait: 800 });

  p = await page("gantt", "/", { height: 900 });
  await shot(p, "example-gantt", { wait: 800 });

  p = await page("monitor", "/", { height: 860, appearance: dark() });
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "example-monitor", { wait: 1500 });

  // accounts: the first sign-up (the demo login) becomes the admin; its users page
  ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: 1 });
  p = await ctx.newPage();
  await p.goto(`http://127.0.0.1:${apps.accounts}/auth/register`);
  await p.getByLabel("Username").fill("alice");
  await p.getByLabel("Full name").fill("Alice");
  await p.getByLabel("Password", { exact: true }).fill("streamlitd-demo");
  await p.getByLabel("Repeat the password").fill("streamlitd-demo");
  await p.getByRole("button", { name: "Create account" }).click();
  await p.waitForURL((u) => !u.pathname.startsWith("/auth/"));
  await ready(p);
  await p.goto(`http://127.0.0.1:${apps.accounts}/admin`);
  await ready(p);
  await shot(p, "example-accounts", { wait: 800 });

  p = await page("api", "/", { height: 760 });
  await shot(p, "example-api");
  p = await page("custom", "/", { height: 860 });
  await shot(p, "example-custom", { wait: 1000 });
  p = await page("business", "/suppliers", { height: 760 });
  await shot(p, "example-business", { wait: 800 });
  p = await page("prod", "/app/", { height: 700 });
  await shot(p, "example-prod");
  }

  async function tutorialShots() {
  p = await page("tutorial", "/", { height: 860 });
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "tutorial", { wait: 1200 });
  p = await page("tutorial", "/", { height: 860 });
  await rerun(p, () => p.getByRole("button", { name: "Remove West" }).click());
  await rerun(p, () => p.getByRole("button", { name: "Gadget" }).click());
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "tutorial-filters", { wait: 1200 });
  p = await page("tutorial", "/", { height: 860 });
  await p.getByRole("tab", { name: "🗂 Data" }).click();
  await shot(p, "tutorial-data");
  p = await page("tutorial", "/", { height: 1100 });
  await p.getByText("➕ Add a sale").click();
  await p.getByRole("spinbutton", { name: "Units" }).fill("25");
  await p.getByRole("combobox", { name: "Product" }).click();
  await p.locator("#stPopups .st-option", { hasText: /^Gadget$/ }).click();
  await p.getByText("➕ Add a sale").scrollIntoViewIfNeeded();
  await shot(p, "tutorial-form");
  p = await page("tutorial", "/", { height: 860, appearance: look("finance", "xp", "dark") });
  await p.waitForSelector("[data-testid=st-vega-lite][data-rendered]");
  await shot(p, "tutorial-dark", { wait: 1200 });
  }

})().catch((e) => { console.error(e); process.exitCode = 1; }).finally(async () => {
  if (browser) await browser.close().catch(() => {});
  procs.forEach((p) => p.kill());
});
