const { test } = require("@playwright/test");
const path = require("path");
const fs = require("fs");
const { open, rerun, widget, expect } = require("./helpers");

test("dataframe renders, sorts and searches", async ({ page }) => {
  await open(page, "data");
  const df = page.getByTestId("st-dataframe").first();
  await expect(df.locator("tbody tr")).toHaveCount(24);
  await df.locator("th", { hasText: "units" }).click();
  await expect(df.locator("tbody tr").first().locator("td").nth(3)).toHaveText("10");
  await df.locator("th", { hasText: "units" }).click();
  await expect(df.locator("tbody tr").first().locator("td").nth(3)).toHaveText("49");
  await df.getByPlaceholder("Search").fill("Gadget");
  await expect(df.locator("tbody tr")).toHaveCount(8);
});

test("sidebar filter reruns and updates metrics and table", async ({ page }) => {
  await open(page, "data");
  await rerun(page, () => page.getByRole("button", { name: "Remove North" }).click());
  await expect(page.getByTestId("st-metric").first().locator(".metric-value")).toHaveText("18");
  await expect(page.getByTestId("st-dataframe").first().locator("tbody tr")).toHaveCount(18);
});

test("charts render with vega-lite", async ({ page }) => {
  await open(page, "data");
  const charts = page.getByTestId("st-vega-lite");
  await expect(charts).toHaveCount(5);
  for (let i = 0; i < 5; i++) {
    await expect(charts.nth(i)).toHaveAttribute("data-rendered", "1");
    await expect(charts.nth(i).locator("svg.marks")).toBeVisible();
  }
});

test("data editor edits, adds and deletes rows", async ({ page }) => {
  await open(page, "data");
  const ed = page.getByTestId("st-data-editor");
  await expect(page.getByText("Total hours: 6, done: 1/3")).toBeVisible();
  await rerun(page, async () => { const c = ed.getByLabel("hours row 1"); await c.fill("10"); await c.press("Enter"); });
  await expect(page.getByText("Total hours: 15, done: 1/3")).toBeVisible();
  await rerun(page, () => ed.getByLabel("done row 2").check());
  await expect(page.getByText("Total hours: 15, done: 2/3")).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "+ Add row" }).click());
  await expect(ed.locator("tbody tr")).toHaveCount(4);
  await rerun(page, async () => { const c = ed.getByLabel("hours row 3"); await c.fill("4"); await c.press("Enter"); });
  await expect(page.getByText("Total hours: 19, done: 2/4")).toBeVisible();
  await ed.getByLabel("Select row 0").check();
  await rerun(page, () => page.getByRole("button", { name: "Delete selected" }).click());
  await expect(page.getByText("Total hours: 16, done: 1/3")).toBeVisible();
  await expect(ed.locator("tbody tr")).toHaveCount(3);
});

test("file upload and download", async ({ page }) => {
  await open(page, "data");
  await rerun(page, () => page.getByTestId("st-file-input").setInputFiles(path.join(__dirname, "../fixtures/people.csv")));
  await expect(page.getByText("Uploaded people.csv (")).toBeVisible();
  const up = page.getByTestId("st-dataframe").nth(1);
  await expect(up.locator("tbody tr")).toHaveCount(3);
  await expect(up.locator("tbody tr").nth(1)).toContainText("Bob");
  // remove the file
  await rerun(page, () => page.getByTestId("st-uploaded-file").getByRole("button", { name: "Remove" }).click());
  await expect(page.getByText("Uploaded people.csv")).toHaveCount(0);

  const [download] = await Promise.all([
    page.waitForEvent("download"),
    page.getByRole("button", { name: "Download sales CSV" }).click(),
  ]);
  expect(download.suggestedFilename()).toBe("sales.csv");
  const content = fs.readFileSync(await download.path(), "utf8");
  expect(content.split("\n")[0]).toBe("region,product,units,revenue");
  expect(content.trim().split("\n")).toHaveLength(25);
});

test("image and json", async ({ page }) => {
  await open(page, "data");
  const img = page.getByTestId("st-image").locator("img");
  await expect(img).toBeVisible();
  const ok = await img.evaluate((i) => i.complete && i.naturalWidth > 0);
  expect(ok).toBe(true);
  await expect(page.getByTestId("st-json")).toContainText('"streamlitd"');
});
