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
  const up = page.getByTestId("st-dataframe").last(); // the uploaded file is the last table
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

test("column configuration: formats, colours, grouped header, totals follow the search", async ({ page }) => {
  await open(page, "data");
  const t = page.getByTestId("st-dataframe").nth(1);
  // grouped header above Units/Revenue/Change; hidden column not shown; labels and tooltips
  await expect(t.locator("thead tr.group-row th.named")).toHaveText("This month");
  await expect(t.locator("thead tr:last-child th")).toHaveText(["Region", "Units", "Revenue", "Change", "Target reached", "Updated", "Site"]);
  await expect(t.locator("thead th", { hasText: "Change" })).toHaveAttribute("title", "Compared with last month");
  const north = t.locator("tbody tr").first();
  await expect(north.locator("td").nth(2)).toContainText("12,501");
  await expect(north.locator("td").nth(2).locator(".cell-detail")).toHaveText("28% of total");
  await expect(north.locator("td").nth(3)).toHaveText("+13.6%");
  await expect(north.locator("td").nth(3)).toHaveClass(/cs-text-success/);
  await expect(north.locator("td").nth(5)).toHaveText("02.11.2026");
  await expect(north.locator("td").nth(6).getByRole("link", { name: "Open" })).toHaveAttribute("href", "https://example.com/north");
  await expect(t.locator("tbody tr").nth(1).locator("td").nth(1)).toHaveClass(/cs-bg-warning/); // cellStyle: units < 100
  const totals = t.locator("tfoot tr.totals");
  await expect(totals.locator("th, td").nth(0)).toHaveText("Total");
  await expect(totals.locator("td").nth(0)).toHaveText("446");
  await expect(totals.locator("td").nth(1)).toHaveText("44,631");
  // totals are computed over the rows shown
  await t.getByPlaceholder("Search").fill("North");
  await expect(t.locator("tbody tr")).toHaveCount(1);
  await expect(totals.locator("td").nth(0)).toHaveText("120");
  await t.getByPlaceholder("Search").fill("");
  // sorting with the keyboard; totals stay at the bottom
  const units = t.getByRole("button", { name: "Sort by Units" });
  await units.focus();
  await page.keyboard.press("Enter");
  await expect(t.locator("thead th", { hasText: "Units" })).toHaveAttribute("aria-sort", "ascending");
  await expect(t.locator("tbody tr").first().locator("td").first()).toHaveText("West");
  await expect(t.getByRole("button", { name: "Sort by Units" })).toBeFocused();
  await expect(totals).toBeVisible();
});

test("data editor follows the column configuration", async ({ page }) => {
  await open(page, "data");
  const ed = page.getByTestId("st-data-editor");
  // select column: a themed drop-down with the options
  await rerun(page, async () => {
    await ed.getByRole("combobox", { name: "Priority row 1" }).click();
    await page.locator("#stPopups .st-option", { hasText: "high" }).click();
  });
  await expect(ed.getByRole("combobox", { name: "Priority row 1" })).toHaveValue("high");
  // a number outside min/max is not sent
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  const h = ed.getByLabel("Hours row 0");
  await h.fill("30");
  await h.press("Enter");
  await expect(h.locator("xpath=..")).toHaveClass(/invalid/);
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs);
  await expect(page.getByText("Total hours: 6, done: 1/3")).toBeVisible();
});

test("tree rows: groups with sums, open and close, select a row or a group, keyboard", async ({ page }) => {
  await open(page, "data");
  const t = page.getByTestId("st-dataframe").nth(2);
  // level 1 open at first: managers and their suppliers; brands are inside closed suppliers
  await expect(t.locator("tr.tree-group")).toHaveText([/Ann\s*3\s*28\s*2,830/, /ACME/, /Globex/, /Bob/, /Initech/]);
  await expect(t.locator("tr", { hasText: "Rocket" })).toHaveCount(0);
  await expect(t.locator("tfoot")).toContainText("43");
  await t.locator("tr.tree-group", { hasText: "ACME" }).getByRole("button", { name: "Expand ACME" }).click();
  await expect(t.locator("tbody tr").nth(2)).toContainText("Rocket");
  // sorting keeps brands under their supplier
  await t.getByRole("button", { name: "Sort by orders" }).click();
  // groups sort by their sums (Bob 15 < Ann 28), brands within their supplier (Anvil 7 < Rocket 12)
  await expect(t.locator("tbody tr")).toHaveText([/Bob/, /Initech/, /Ann/, /Globex/, /ACME/, /Anvil/, /Rocket/]);
  // select a brand: the app gets its key
  await rerun(page, () => t.locator("tr", { hasText: "Anvil" }).click());
  await expect(page.getByText("Selected brand: b2")).toBeVisible();
  await expect(t.locator("tr", { hasText: "Anvil" })).toHaveAttribute("aria-selected", "true");
  // the same row again clears it
  await rerun(page, () => t.locator("tr", { hasText: "Anvil" }).click());
  await expect(page.getByText("Click a brand or a group.")).toBeVisible();
  // keyboard: ↑/↓ move, ← closes, → opens, Enter selects (a group here)
  await t.locator("tr", { hasText: "Rocket" }).click({ position: { x: 5, y: 5 } }).catch(() => {});
  await page.waitForFunction(() => document.body.dataset.running === "0");
  const bob = t.locator("tr.tree-group", { hasText: "Bob" });
  await bob.focus();
  await page.keyboard.press("ArrowLeft");
  await expect(bob).toHaveAttribute("aria-expanded", "false");
  await page.keyboard.press("ArrowRight");
  await expect(t.locator("tr.tree-group", { hasText: "Bob" })).toHaveAttribute("aria-expanded", "true");
  await rerun(page, () => page.keyboard.press("Enter"));
  await expect(page.getByText("Selected group: Bob")).toBeVisible();
  await expect(t.locator("tr.tree-group", { hasText: "Bob" })).toBeFocused(); // focus stays after the rerun
  // Collapse all
  await t.getByRole("button", { name: "Collapse all" }).click();
  await expect(t.locator("tbody tr")).toHaveCount(2);
});

test("multi-row selection: checkboxes, Shift-click ranges, select all", async ({ page }) => {
  await open(page, "data");
  const t = page.getByTestId("st-dataframe").nth(3);
  await rerun(page, () => t.locator("tbody tr").nth(1).click());
  await rerun(page, () => t.locator("tbody tr").nth(3).click({ modifiers: ["Shift"] }));
  await expect(page.getByText("Selected rows: [1, 2, 3]")).toBeVisible();
  await expect(t.getByRole("checkbox", { name: "Select all rows" })).toHaveJSProperty("indeterminate", true);
  await rerun(page, () => t.getByRole("checkbox", { name: "Select all rows" }).click());
  await expect(page.getByText("Selected rows: [1, 2, 3, 0, 4, 5]")).toBeVisible();
  await rerun(page, () => t.getByRole("checkbox", { name: "Select all rows" }).click());
  await expect(page.getByText("Selected rows: []")).toBeVisible();
});
