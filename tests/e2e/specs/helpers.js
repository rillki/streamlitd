const { expect } = require("@playwright/test");
const { apps, basePaths } = require("../playwright.config.js");

const url = (app, p = "/") => `http://127.0.0.1:${apps[app]}${basePaths[app] || ""}${p}`;

/** Open an app and wait for the first run to finish. */
async function open(page, app, p = "/") {
  await page.goto(url(app, p));
  await waitIdle(page, 1);
}

/** Wait until at least `n` runs finished and nothing is running. */
async function waitIdle(page, n) {
  await page.waitForFunction((n) => +(document.body.dataset.runs || 0) >= n && document.body.dataset.running === "0", n);
}

/** Run an action and wait for the rerun it triggers to finish. */
async function rerun(page, action) {
  const before = await page.evaluate(() => +(document.body.dataset.runs || 0));
  await action();
  await waitIdle(page, before + 1);
}

/** Locate a widget container by its label. */
const widget = (page, kind, label) => page.locator(`[data-testid="st-${kind}"][data-label="${label}"]`);

module.exports = { url, open, waitIdle, rerun, widget, expect };
