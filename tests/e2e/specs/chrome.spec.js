// Header controls: ⟳ (rerun) and ⚙ (appearance) in the header, in one ⋮ menu, or hidden,
// and st.settingsButton() opening the appearance panel from anywhere. examples/hello runs three
// times: with the defaults, with --rerun-button/--settings-button menu, and with both hidden.
const { test } = require("@playwright/test");
const { open, rerun, waitIdle, expect } = require("./helpers");

const runs = (page) => page.evaluate(() => +document.body.dataset.runs);
const inViewport = (page, loc) => loc.evaluate((el) => {
  const r = el.getBoundingClientRect();
  return r.left >= 0 && r.top >= 0 && r.right <= document.documentElement.clientWidth && r.bottom <= window.innerHeight;
});

test("defaults: ⟳ and ⚙ in the header; the sidebar button opens the panel next to it", async ({ page }) => {
  await open(page, "hello");
  await expect(page.getByRole("button", { name: "Rerun", exact: true })).toBeVisible();
  await expect(page.getByTestId("st-settings")).toBeVisible();
  await expect(page.getByTestId("st-app-menu")).toBeHidden();
  const panel = page.getByTestId("st-settings-panel");
  // from the header
  await page.getByTestId("st-settings").click();
  await expect(panel).toBeVisible();
  expect(await inViewport(page, panel)).toBe(true);
  await page.getByTestId("st-settings").click();
  await expect(panel).toBeHidden();
  // from the sidebar: next to the button, inside the viewport; Esc closes it and returns focus
  const b = page.getByTestId("st-settings-button");
  await b.click();
  await expect(panel).toBeVisible();
  await expect(b).toHaveAttribute("aria-expanded", "true");
  const [pb, bb] = [await panel.boundingBox(), await b.boundingBox()];
  expect(Math.abs(pb.x - bb.x)).toBeLessThan(2);
  // below or above the button, never on top of it
  expect(pb.y >= bb.y + bb.height || pb.y + pb.height <= bb.y).toBe(true);
  expect(await inViewport(page, panel)).toBe(true);
  // the mode can be changed from there; nested pop-ups (design list) do not close the panel
  await panel.getByRole("button", { name: "Dark" }).click();
  await expect(panel.getByRole("button", { name: "Dark" })).toHaveAttribute("aria-pressed", "true");
  await page.getByTestId("st-design-select").click();
  await page.keyboard.press("Escape");
  await expect(panel).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await expect(b).toBeFocused();
  // an outside click closes it
  await b.click();
  await page.locator("h1").click();
  await expect(panel).toBeHidden();
});

test("menu: ⟳ and ⚙ move into one ⋮ menu", async ({ page }) => {
  await open(page, "hello-menu");
  await expect(page.getByRole("button", { name: "Rerun", exact: true })).toBeHidden();
  await expect(page.getByTestId("st-settings")).toBeHidden();
  const menu = page.getByTestId("st-app-menu");
  await expect(menu).toBeVisible();
  await menu.click();
  await expect(page.getByRole("menuitem")).toHaveText([/Rerun/, /Appearance/]);
  const before = await runs(page);
  await page.getByRole("menuitem", { name: /Rerun/ }).click();
  await waitIdle(page, before + 1);
  await menu.click();
  await page.getByRole("menuitem", { name: /Appearance/ }).click();
  const panel = page.getByTestId("st-settings-panel");
  await expect(panel).toBeVisible();
  expect(await inViewport(page, panel)).toBe(true);
  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await expect(menu).toBeFocused();
  // the R shortcut still works
  await page.locator("h1").click();
  await rerun(page, () => page.keyboard.press("r"));
});

test("hidden: no header controls, no R shortcut; the app's own button still works", async ({ page }) => {
  await open(page, "hello-hidden");
  await expect(page.getByRole("button", { name: "Rerun", exact: true })).toBeHidden();
  await expect(page.getByTestId("st-settings")).toBeHidden();
  await expect(page.getByTestId("st-app-menu")).toBeHidden();
  await page.locator("h1").click();
  const before = await runs(page);
  await page.keyboard.press("r");
  await page.waitForTimeout(400);
  expect(await runs(page)).toBe(before);
  await page.getByTestId("st-settings-button").click();
  await expect(page.getByTestId("st-settings-panel")).toBeVisible();
});

test("the panel opened inside a popover keeps it open, and sits above dialogs", async ({ page }) => {
  await open(page, "widgets");
  await page.getByRole("tab", { name: "Layout" }).click();
  await page.getByRole("button", { name: "Open popover" }).click();
  const b = page.locator(".popover-panel").getByTestId("st-settings-button");
  await b.click();
  const panel = page.getByTestId("st-settings-panel");
  await panel.getByRole("button", { name: "Dark" }).click();
  await expect(panel).toBeVisible();
  await expect(page.locator(".popover-panel")).toBeVisible(); // a click in the panel is not "outside" the popover
  await page.keyboard.press("Escape");
  await expect(panel).toBeHidden();
  await expect(b).toBeFocused();
  // st.settingsButton() can sit in a dialog: the panel must be above the dialog overlay
  const [pz, dz] = await page.evaluate(() => {
    const d = document.createElement("div");
    d.className = "dialog-overlay";
    d.style.visibility = "hidden";
    document.body.appendChild(d);
    const r = [+getComputedStyle(document.getElementById("stSettingsPanel")).zIndex, +getComputedStyle(d).zIndex];
    d.remove();
    return r;
  });
  expect(pz).toBeGreaterThan(dz);
});
