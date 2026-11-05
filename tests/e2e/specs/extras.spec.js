const { test } = require("@playwright/test");
const { open, rerun, expect } = require("./helpers");

test("latex and markdown math render with KaTeX; code is highlighted", async ({ page }) => {
  await open(page, "extras");
  await expect(page.getByTestId("st-latex").locator(".katex")).toBeVisible();
  const md = page.getByTestId("st-markdown").first();
  await expect(md.locator(".katex")).toHaveCount(2); // inline + display
  await expect(md).toContainText("costs $5"); // currency is not math
  const dcode = page.locator(".code-block").first();
  await expect(dcode.locator("code.hljs .hljs-keyword").first()).toBeVisible();
  await expect(dcode.locator(".line-gutter")).toContainText("7");
  await expect(page.locator(".code-block").nth(1).locator(".hljs-string").first()).toBeVisible();
});

test("plotly chart renders with theme colorway and supports selection", async ({ page }) => {
  await open(page, "extras");
  await page.getByRole("tab", { name: "Plotly" }).click();
  const chart = page.getByTestId("st-plotly");
  await expect(chart).toHaveAttribute("data-rendered", "1");
  await expect(chart.locator(".main-svg").first()).toBeVisible();
  const colorway = await chart.evaluate((d) => d._fullLayout.colorway[0]);
  expect(colorway.toLowerCase()).toBe("#0068c9");
  await expect(page.getByText("selection: none")).toBeVisible();
  // click a marker -> selection event -> rerun
  await rerun(page, () => chart.evaluate((d) => d.emit("plotly_click", { points: [{ curveNumber: 0, pointIndex: 1, x: 2, y: 15 }] })));
  await expect(page.getByText("selection: 1 points")).toBeVisible();
});

test("map renders points with leaflet", async ({ page }) => {
  await open(page, "extras");
  await page.getByRole("tab", { name: "Map" }).click();
  const map = page.getByTestId("st-map");
  await expect(map).toHaveAttribute("data-rendered", "1");
  await expect(map).toHaveAttribute("data-points", "4");
  await expect(map.locator("path.leaflet-interactive")).toHaveCount(4);
});

test("custom component round-trips values; static html renders", async ({ page }) => {
  await open(page, "extras");
  await page.getByRole("tab", { name: "Components" }).click();
  const html = page.frameLocator('[data-testid="st-component-html"]');
  await expect(html.getByText("Static HTML in a sandboxed iframe")).toBeVisible();
  const comp = page.frameLocator('[data-testid="st-component"]');
  await expect(comp.getByText("A D-declared component (clicked 0 times)")).toBeVisible();
  await expect(page.getByText("Component value: count = 0")).toBeVisible();
  await rerun(page, () => comp.getByRole("button", { name: "Click me" }).click());
  await expect(page.getByText("Component value: count = 1")).toBeVisible();
  await rerun(page, () => comp.getByRole("button", { name: "Click me" }).click());
  await expect(page.getByText("Component value: count = 2")).toBeVisible();
  // frame height was set by the component
  expect(await page.getByTestId("st-component").evaluate((f) => f.style.height)).toBe("56px");
});
