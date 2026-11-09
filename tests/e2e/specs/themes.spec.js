const { test } = require("@playwright/test");
const { open, rerun, expect, pick } = require("./helpers");

const cssVar = (page, name) => page.evaluate((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), name);
const side = (page) => page.getByTestId("st-sidebar");
const html = (page) => page.locator("html");
const designs = ["streamlit", "terminal", "retro", "win95", "xp", "brutalist", "material", "glass"];

test("st.setTheme applies color scheme and mode", async ({ page }) => {
  await open(page, "themes");
  expect(await cssVar(page, "--primary")).toBe("#ff4b4b");
  await rerun(page, () => pick(page, side(page).getByLabel("Color scheme"), "ocean"));
  expect(await cssVar(page, "--primary")).toBe("#0068c9");
  await expect(html(page)).toHaveAttribute("data-scheme", "ocean");
  await expect(html(page)).toHaveAttribute("data-style", "ocean");
  await rerun(page, () => side(page).getByLabel("dark", { exact: true }).check());
  await expect(html(page)).toHaveAttribute("data-theme", "dark");
  expect(await cssVar(page, "--bg")).toBe("#0b1724");
  // charts use the scheme's palette
  const chart = page.getByTestId("st-vega-lite").first();
  await expect(chart).toHaveAttribute("data-rendered", "1");
  const strokes = await chart.locator("path[stroke]").evaluateAll((ps) => ps.map((p) => p.getAttribute("stroke")));
  expect(strokes).toContain("#4da3ff");
});

test("custom override on top of a scheme", async ({ page }) => {
  await open(page, "themes");
  await rerun(page, () => side(page).getByLabel("Custom primary color").check());
  expect(await cssVar(page, "--primary")).toBe("#7c3aed");
});

test("each design style changes the UI structure", async ({ page }) => {
  await open(page, "themes");
  const btn = () => page.getByRole("button", { name: "Secondary" });
  const style = (loc, prop) => loc.evaluate((e, p) => getComputedStyle(e)[p], prop);
  const probes = {
    streamlit: async () => expect(await style(btn(), "borderTopWidth")).toBe("1px"),
    terminal: async () => {
      expect(await cssVar(page, "--font")).toContain("monospace");
      // charts re-render with the design's font
      const label = page.getByTestId("st-vega-lite").first().locator("g.role-axis-label text").first();
      await expect.poll(() => label.evaluate((t) => t.getAttribute("font-family") || getComputedStyle(t).fontFamily)).toContain("monospace");
      expect(await btn().evaluate((e) => getComputedStyle(e, "::before").content)).toContain('"[ "');
    },
    retro: async () => expect(await style(btn(), "boxShadow")).toMatch(/4px 4px 0px/),
    win95: async () => {
      expect(await style(btn(), "boxShadow")).toContain("inset");
      expect(await cssVar(page, "--radius")).toBe("0");
    },
    xp: async () => expect(await style(page.locator("details.expander > summary"), "backgroundImage")).toContain("linear-gradient"),
    brutalist: async () => expect(await style(btn(), "borderTopWidth")).toBe("3px"),
    material: async () => expect(parseFloat(await style(btn(), "borderTopLeftRadius"))).toBeGreaterThan(100),
    glass: async () => expect(await style(page.locator("details.expander"), "backdropFilter")).toContain("blur"),
  };
  for (const d of designs) {
    await rerun(page, () => pick(page, side(page).getByLabel("Design style"), d));
    await expect(html(page)).toHaveAttribute("data-design", d);
    await probes[d]();
    // charts re-render in every design
    await expect(page.getByTestId("st-vega-lite").first()).toHaveAttribute("data-rendered", "1");
  }
});

test("design × scheme × mode combine", async ({ page }) => {
  await open(page, "themes");
  await rerun(page, () => pick(page, side(page).getByLabel("Design style"), "xp"));
  await rerun(page, () => pick(page, side(page).getByLabel("Color scheme"), "ocean"));
  await rerun(page, () => side(page).getByLabel("dark", { exact: true }).check());
  await expect(html(page)).toHaveAttribute("data-design", "xp");
  await expect(html(page)).toHaveAttribute("data-scheme", "ocean");
  await expect(html(page)).toHaveAttribute("data-theme", "dark");
  // xp forces its font, the scheme still provides the colors
  expect(await cssVar(page, "--font")).toContain("Tahoma");
  expect(await cssVar(page, "--primary")).toBe("#4da3ff");
  // a dialog gets the design's title bar
  await rerun(page, () => page.getByRole("button", { name: "Open dialog" }).click());
  const head = page.getByRole("dialog").locator(".dialog-head");
  expect(await head.evaluate((e) => getComputedStyle(e).backgroundImage)).toContain("gradient");
});

test("viewer menu changes design, scheme and mode independently and persists", async ({ page }) => {
  await open(page, "themes");
  await page.getByTestId("st-settings").click();
  await pick(page, page.getByTestId("st-scheme-select"), "Paper");
  await expect(html(page)).toHaveAttribute("data-scheme", "paper");
  expect(await cssVar(page, "--font")).toContain("Georgia");
  await pick(page, page.getByTestId("st-design-select"), "Terminal");
  await expect(html(page)).toHaveAttribute("data-design", "terminal");
  await expect(html(page)).toHaveAttribute("data-scheme", "paper"); // unchanged
  expect(await cssVar(page, "--font")).toContain("monospace");      // design font wins over the scheme font
  await page.getByRole("button", { name: "Dark", exact: true }).click();
  await expect(html(page)).toHaveAttribute("data-theme", "dark");
  // preview cards
  await page.locator('[data-design-card="win95"]').click();
  await expect(html(page)).toHaveAttribute("data-design", "win95");
  await page.reload();
  await page.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1);
  await expect(html(page)).toHaveAttribute("data-design", "win95");
  await expect(html(page)).toHaveAttribute("data-scheme", "paper");
  await expect(html(page)).toHaveAttribute("data-theme", "dark");
  // an explicit change by the app wins over the viewer's choice
  await rerun(page, () => pick(page, side(page).getByLabel("Design style"), "glass"));
  await expect(html(page)).toHaveAttribute("data-design", "glass");
});

test("app can lock the appearance menu", async ({ page }) => {
  await open(page, "themes");
  await expect(page.getByTestId("st-settings")).toBeVisible();
  await rerun(page, () => side(page).getByLabel("Lock appearance for viewers").check());
  await expect(page.getByTestId("st-settings")).toBeHidden();
});

test("every design stays usable: button, slider, form, tab, dialog", async ({ page }) => {
  await open(page, "themes");
  for (const d of designs) {
    await rerun(page, () => pick(page, side(page).getByLabel("Design style"), d));
    await rerun(page, () => page.getByRole("button", { name: "Primary", exact: true }).click());
    await rerun(page, async () => {
      const s = page.locator('[data-testid="st-slider"][data-label="Slider"] input[type=range]');
      await s.focus();
      await s.press("ArrowRight");
    });
    await page.getByRole("tab", { name: "Form" }).click();
    await rerun(page, () => page.getByRole("button", { name: "Submit" }).click());
    await page.getByRole("tab", { name: "Table" }).click();
    await rerun(page, () => page.getByRole("button", { name: "Open dialog" }).click());
    const dlg = page.getByRole("dialog", { name: "A dialog" });
    await expect(dlg).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(dlg).toBeHidden();
  }
});
