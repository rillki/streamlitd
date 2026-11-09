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

// ---- themed controls (assets/ui.js) — no native <select>/<input type=date|time|color> ----
const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** The open popup's option whose label is exactly `option`. */
const optionIn = (page, option) =>
  page.locator("#stPopups .st-option").filter({ has: page.locator(".st-option-label", { hasText: new RegExp("^" + esc(option) + "$") }) }).first();

/** Choose `option` in a combobox (selectbox, settings menu). `combo` is a locator or a label. */
async function pick(page, combo, option) {
  const cb = typeof combo === "string" ? page.getByRole("combobox", { name: combo, exact: true }) : combo;
  await cb.click();
  await optionIn(page, option).click();
}

/** Toggle options in a multiselect, then close it. */
async function pickMany(page, combo, options) {
  const cb = typeof combo === "string" ? page.getByRole("combobox", { name: combo, exact: true }) : combo;
  await cb.click();
  for (const o of options) await optionIn(page, o).click();
  await cb.press("Escape");
}

/** Type a date (YYYY-MM-DD), time (HH:MM) into a picker input and commit with Enter. */
async function typeAndEnter(page, label, value) {
  const inp = page.getByLabel(label, { exact: true });
  await inp.fill(value);
  await inp.press("Enter");
}
const setDate = typeAndEnter;
const setTime = typeAndEnter;

/** Set a color picker through its hex field. */
async function setColor(page, label, hex) {
  await page.getByLabel(label, { exact: true }).click();
  const field = page.locator("#stPopups").getByLabel("Hex color");
  await field.fill(hex);
  await field.press("Enter");
}

module.exports = { url, open, waitIdle, rerun, widget, expect, pick, pickMany, optionIn, setDate, setTime, setColor };
