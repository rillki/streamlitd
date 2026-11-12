// Playwright config: builds and starts every example app on its own port.
const path = require("path");
const os = require("os");
const fs = require("fs");

const root = path.resolve(__dirname, "../..");
const apps = { hello: 8701, widgets: 8702, data: 8703, multipage: 8704, themes: 8705, prod: 8706, fragments: 8707, extras: 8708, auth: 8709, tutorial: 8710, api: 8711, custom: 8713, accounts: 8714 };
// apps served under a base URL path (from their config.toml)
const basePaths = { prod: "/app" };
// environment for an app's command (the auth app also serves its API docs, switched on by env var);
// the apps with logins keep their user store in a fresh temporary folder per run
const userDir = (name) => path.join(os.tmpdir(), "streamlitd-e2e-" + name);
const appEnv = {
  auth: `rm -rf ${userDir("auth")} && STREAMLITD_AUTH_USERS_FILE=${userDir("auth")}/users.json STREAMLITD_API_DOCS=true `,
  accounts: `rm -rf ${userDir("accounts")} && STREAMLITD_AUTH_USERS_FILE=${userDir("accounts")}/users.json `,
};

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
    actionTimeout: 5000,
  },
  webServer: [{
    command: `node ${__dirname}/fixtures/mock-oidc.js`,
    url: "http://127.0.0.1:8790/health",
    reuseExistingServer: !process.env.CI,
  }].concat(Object.entries(apps).map(([name, port]) => ({
    command: `cd ${root}/examples/${name} && dub build --compiler=${process.env.DC || "ldc2"} -q && ${appEnv[name] || ""}./${name} --port ${port} --host 127.0.0.1 --quiet`,
    url: `http://127.0.0.1:${port}${basePaths[name] || ""}/_stcore/health`,
    timeout: 600000,
    reuseExistingServer: !process.env.CI,
  })), {
    // the api example a second time, under a base path (built by the entry above)
    command: `cd ${root}/examples/api && until [ -x ./api ] && curl -sf http://127.0.0.1:8711/_stcore/health >/dev/null; do sleep 1; done; ./api --port 8712 --host 127.0.0.1 --quiet --base-url-path /sub --api-docs=false`,
    url: "http://127.0.0.1:8712/sub/_stcore/health",
    timeout: 600000,
    reuseExistingServer: !process.env.CI,
  }),
};
module.exports.apps = apps;
module.exports.basePaths = basePaths;
