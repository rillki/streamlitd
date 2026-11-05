// Playwright config: builds and starts every example app on its own port.
const path = require("path");
const os = require("os");
const fs = require("fs");

const root = path.resolve(__dirname, "../..");
const apps = { hello: 8701, widgets: 8702, data: 8703, multipage: 8704, themes: 8705, prod: 8706, fragments: 8707, extras: 8708, auth: 8709, tutorial: 8710 };
// apps served under a base URL path (from their config.toml)
const basePaths = { prod: "/app" };

// Use a locally installed Chromium if the bundled one is missing (override with CHROMIUM_PATH).
let executablePath = process.env.CHROMIUM_PATH;
if (!executablePath) {
  const cache = path.join(os.homedir(), ".cache/ms-playwright");
  try {
    const dirs = fs.readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse();
    for (const d of dirs) {
      const p = path.join(cache, d, "chrome-linux64/chrome");
      if (fs.existsSync(p)) { executablePath = p; break; }
    }
  } catch (e) {}
}

module.exports = {
  testDir: "./specs",
  timeout: 30000,
  expect: { timeout: 8000 },
  fullyParallel: true,
  workers: 4,
  reporter: [["list"]],
  use: {
    viewport: { width: 1280, height: 900 },
    launchOptions: executablePath ? { executablePath } : {},
    trace: "retain-on-failure",
  },
  webServer: [{
    command: `node ${__dirname}/fixtures/mock-oidc.js`,
    url: "http://127.0.0.1:8790/health",
    reuseExistingServer: !process.env.CI,
  }].concat(Object.entries(apps).map(([name, port]) => ({
    command: `cd ${root}/examples/${name} && dub build --compiler=${process.env.DC || "ldc2"} -q && ./${name} --port ${port} --host 127.0.0.1 --quiet`,
    url: `http://127.0.0.1:${port}${basePaths[name] || ""}/_stcore/health`,
    timeout: 600000,
    reuseExistingServer: !process.env.CI,
  }))),
};
module.exports.apps = apps;
module.exports.basePaths = basePaths;
