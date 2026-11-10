// Rasterize assets/favicon.svg to PNGs (run from tests/e2e: node ../../tools/gen_favicon.js),
// then `python3 tools/gen_favicon.py` builds favicon.ico and `python3 tools/gen_assets.py` embeds them.
const path = require("path");
const fs = require("fs");
const os = require("os");
const { chromium } = require(path.join(process.cwd(), "node_modules", "playwright"));

const assets = path.resolve(__dirname, "..", "assets");
const svg = fs.readFileSync(path.join(assets, "favicon.svg"), "utf8");
function chromePath() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const cache = path.join(os.homedir(), ".cache/ms-playwright");
  for (const d of fs.readdirSync(cache).filter((d) => /^chromium-\d+$/.test(d)).sort().reverse()) {
    const p = path.join(cache, d, "chrome-linux64/chrome");
    if (fs.existsSync(p)) return p;
  }
}
(async () => {
  const browser = await chromium.launch({ executablePath: chromePath() });
  const page = await browser.newPage();
  const sizes = { "favicon-16.png": 16, "favicon-32.png": 32, "favicon-48.png": 48, "apple-touch-icon.png": 180 };
  for (const [name, size] of Object.entries(sizes)) {
    await page.setViewportSize({ width: size, height: size });
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg.replace("<svg ", `<svg width="${size}" height="${size}" `)}</body></html>`);
    await page.screenshot({ path: path.join(assets, name), omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
    console.log(name);
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
