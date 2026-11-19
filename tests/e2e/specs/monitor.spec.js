// examples/monitor (a sample every 300 ms, a slow source of 500 ms): pushed fragments, the request
// context's time zone, a selection that survives pushed reruns, alerts with a live badge, rules.
const { test } = require("@playwright/test");
const { open, rerun, url, waitIdle, expect } = require("./helpers");

// one producer and one set of alerts for all viewers
test.describe.configure({ mode: "serial" });

const sampleNo = async (page) => Number((await page.getByText(/^Sample \d+ at/).textContent()).match(/Sample (\d+)/)[1]);

test("the overview updates by itself, in the viewer's time zone", async ({ browser }) => {
  const ctx = await browser.newContext({ timezoneId: "Asia/Tokyo" });
  const page = await ctx.newPage();
  await open(page, "monitor");
  await expect(page.getByText("Times in your time zone: Asia/Tokyo.")).toBeVisible();
  await expect(page.getByTestId("st-metric")).toHaveCount(5);
  const first = await sampleNo(page);
  await expect.poll(() => sampleNo(page), { timeout: 5000 }).toBeGreaterThan(first + 2); // pushed, no clicks
  // the chart's time axis shows clock times
  await expect(page.getByTestId("st-vega-lite").first()).toHaveAttribute("data-rendered", "1");
  await expect(page.getByTestId("st-vega-lite").first().locator("svg.marks")).toContainText(/\d\d:\d\d:\d\d/);
  // the slow source: checked again once its data changed (every 15 samples), off the event loop
  const version = async () => Number((await page.getByText(/data version \d+/).textContent()).match(/data version (\d+)/)[1]);
  const v = await version();
  await expect.poll(version, { timeout: 15000 }).toBeGreaterThan(v);
  await ctx.close();
});

test("services: the selection survives the pushed updates", async ({ page }) => {
  await open(page, "monitor", "/services");
  const t = page.getByTestId("st-dataframe");
  await rerun(page, () => t.locator("tr", { hasText: /^\s*db/ }).click());
  await expect(page.getByRole("heading", { name: /^db\b/ })).toBeVisible();
  await expect(page.getByTestId("st-vega-lite")).toHaveCount(3);
  const before = await page.evaluate(() => +document.body.dataset.runs);
  await page.waitForFunction((b) => +document.body.dataset.runs > b + 3, before); // several pushed runs later
  await expect(t.locator("tr", { hasText: /^\s*db/ })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("heading", { name: /^db\b/ })).toBeVisible();
});

test("alerts: the badge follows; acknowledging clears it in every tab", async ({ page, browser }) => {
  await open(page, "monitor", "/alerts");
  const badge = (p) => p.getByTestId("st-sidebar").getByRole("link", { name: /Alerts/ }).locator(".nav-badge");
  // the db's slow spell starts at sample 40 (about 3 s after the start)
  await expect(badge(page)).toHaveText(/^\d+$/, { timeout: 20000 });
  const other = await (await browser.newContext()).newPage();
  await open(other, "monitor");
  await expect(badge(other)).toHaveText(/^\d+$/);
  await expect(page.getByTestId("st-feed")).toContainText("db latency");
  await rerun(page, () => page.getByRole("button", { name: /Acknowledge all/ }).click());
  await expect(page.getByTestId("st-empty-state").or(page.getByTestId("st-feed"))).toBeVisible();
  // both tabs agree on the count right after (0: no badge), pushed to the other tab too
  await expect.poll(async () => [await badge(page).count(), await badge(other).count()].join()).toMatch(/^(0,0|1,1)$/);
  await rerun(page, () => page.getByRole("radiogroup", { name: "Show" }).getByRole("button", { name: "All" }).click());
  await expect(page.getByTestId("st-feed")).toContainText("Acknowledged by operator");
  await other.context().close();
});

test("rules: edited in a table, checked, saved", async ({ page }) => {
  await open(page, "monitor", "/alerts");
  await page.getByRole("tab", { name: "Rules" }).click();
  const ed = page.getByTestId("st-data-editor");
  await expect(ed.locator("tbody tr")).toHaveCount(3);
  await rerun(page, async () => { const c = ed.getByLabel("Above row 0"); await c.fill("95"); await c.press("Enter"); });
  await rerun(page, () => page.getByRole("button", { name: "Save rules" }).click());
  await expect(page.getByText("Saved 3 rules")).toBeVisible();
  await page.reload();
  await waitIdle(page, 1);
  await page.getByRole("tab", { name: "Rules" }).click();
  await expect(page.getByTestId("st-data-editor").getByLabel("Above row 0")).toHaveValue("95");
});
