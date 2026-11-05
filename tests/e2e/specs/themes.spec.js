const { test } = require("@playwright/test");
const { open, rerun, expect } = require("./helpers");

const cssVar = (page, name) => page.evaluate((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), name);

test("st.setTheme applies preset and mode", async ({ page }) => {
  await open(page, "themes");
  expect(await cssVar(page, "--primary")).toBe("#ff4b4b");
  await rerun(page, () => page.getByLabel("App style (st.setTheme)").selectOption("ocean"));
  expect(await cssVar(page, "--primary")).toBe("#0068c9");
  await expect(page.locator("html")).toHaveAttribute("data-style", "ocean");
  await rerun(page, () => page.getByLabel("dark", { exact: true }).check());
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  expect(await cssVar(page, "--bg")).toBe("#0b1724");
  // charts use the preset's palette
  const chart = page.getByTestId("st-vega-lite").first();
  await expect(chart).toHaveAttribute("data-rendered", "1");
  const strokes = await chart.locator("path[stroke]").evaluateAll((ps) => ps.map((p) => p.getAttribute("stroke")));
  expect(strokes).toContain("#4da3ff");
});

test("custom override on top of a preset", async ({ page }) => {
  await open(page, "themes");
  await rerun(page, () => page.getByLabel("Custom primary color").check());
  expect(await cssVar(page, "--primary")).toBe("#7c3aed");
});

test("viewer settings menu changes style and mode and persists", async ({ page }) => {
  await open(page, "themes");
  await page.getByTestId("st-settings").click();
  await page.getByTestId("st-style-select").selectOption("paper");
  await expect(page.locator("html")).toHaveAttribute("data-style", "paper");
  expect(await cssVar(page, "--font")).toContain("Georgia");
  await page.getByRole("button", { name: "Dark", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.reload();
  await page.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1);
  await expect(page.locator("html")).toHaveAttribute("data-style", "paper");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  // an explicit change by the app wins over the viewer's choice
  await rerun(page, () => page.getByLabel("App style (st.setTheme)").selectOption("forest"));
  await expect(page.locator("html")).toHaveAttribute("data-style", "forest");
});

test("app can lock the style menu", async ({ page }) => {
  await open(page, "themes");
  await expect(page.getByTestId("st-settings")).toBeVisible();
  await rerun(page, () => page.getByLabel("Lock style for viewers").check());
  await expect(page.getByTestId("st-settings")).toBeHidden();
});
