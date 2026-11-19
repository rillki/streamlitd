// examples/planning (today fixed to 2026-11-18: Jan–Oct closed): the plan editor with a review
// dialog, plan vs fact as a tree, the delivery calendar with nested dialogs, the CSV import wizard.
const { test } = require("@playwright/test");
const { open, rerun, pick, expect } = require("./helpers");

// one shared plan: a save in one test would be "someone else's save" in another (so the tests run
// one after another, and --repeat-each, which runs the repeats side by side, doesn't fit this file)
test.describe.configure({ mode: "serial" });

test("plan: closed months are read-only; an edit is reviewed, then saved", async ({ page }) => {
  await open(page, "planning");
  const ed = page.getByTestId("st-data-editor");
  await expect(ed.getByLabel("Jan row 0")).toHaveCount(0); // closed: shown, not editable
  await expect(page.getByRole("button", { name: "Review & save" })).toBeDisabled();
  const was = Number((await ed.getByLabel("Dec row 0").inputValue()).replace(/,/g, ""));
  const now = was + 550;
  await rerun(page, async () => { const c = ed.getByLabel("Dec row 0"); await c.fill(String(now)); await c.press("Enter"); });
  await expect(page.getByText("1 unsaved change")).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "Review & save" }).click());
  const dlg = page.getByRole("dialog", { name: "Save 1 change?" });
  await expect(dlg.locator("tbody tr")).toHaveCount(1);
  await expect(dlg.locator("tbody tr")).toContainText("Dec");
  await expect(dlg.locator("tbody tr td.cs-text-success")).toContainText("+550"); // Δ coloured by sign
  await rerun(page, () => dlg.getByRole("button", { name: "Save" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByText("unsaved change")).toHaveCount(0);
  await page.reload();
  expect(Number((await page.getByTestId("st-data-editor").getByLabel("Dec row 0").inputValue()).replace(/,/g, ""))).toBe(now);
});

test("plan: a save by someone else is detected", async ({ page, browser }) => {
  await open(page, "planning");
  const ed = page.getByTestId("st-data-editor");
  await rerun(page, async () => { const c = ed.getByLabel("Nov row 3"); await c.fill("777"); await c.press("Enter"); });
  // another user saves meanwhile
  const ctx = await browser.newContext();
  const other = await ctx.newPage();
  await open(other, "planning");
  const ed2 = other.getByTestId("st-data-editor");
  await rerun(other, async () => { const c = ed2.getByLabel("Nov row 4"); await c.fill("123"); await c.press("Enter"); });
  await rerun(other, () => other.getByRole("button", { name: "Review & save" }).click());
  await rerun(other, () => other.getByRole("dialog").getByRole("button", { name: "Save" }).click());
  await ctx.close();
  // the first user's next action shows the conflict
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByText("Someone else saved the plan")).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "Load the latest plan" }).click());
  await expect(page.getByTestId("st-data-editor").getByLabel("Nov row 4")).toHaveValue("123");
});

test("plan vs fact: tree with grouped headers, sign colours, a brand's months", async ({ page }) => {
  await open(page, "planning", "/plan-vs-fact");
  const t = page.getByTestId("st-dataframe");
  await expect(t.locator("thead tr.group-row th.named")).toHaveText(["Year to date (Jan–Oct)", "Full year"]);
  // group sums and totals are coloured by sign too
  await expect(t.locator("tfoot td.cs-text-error").first()).toBeVisible();
  await t.locator("tr.tree-group", { hasText: "ACME" }).getByRole("button", { name: "Expand ACME" }).click();
  await rerun(page, () => t.locator("tr", { hasText: "Rocket" }).click());
  await expect(page.getByRole("heading", { name: /Rocket · ACME/ })).toBeVisible();
  await expect(page.getByTestId("st-vega-lite")).toHaveAttribute("data-rendered", "1");
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: /Download fact/ }).click();
  expect((await dl).suggestedFilename()).toBe("fact.csv");
});

test("deliveries: a late delivery opens, a nested dialog moves it; an empty day plans one", async ({ page }) => {
  await open(page, "planning", "/deliveries");
  const badge = page.getByTestId("st-sidebar").getByRole("link", { name: /Deliveries/ }).locator(".nav-badge");
  const lateBefore = Number(await badge.textContent()); // 2 in the seed data
  expect(lateBefore).toBeGreaterThan(0);
  const grid = page.getByTestId("st-calendar-grid");
  const late = grid.locator('[data-item][aria-label*="· late"]').first();
  const brand = (await late.getAttribute("aria-label")).split(" · ")[0];
  await rerun(page, () => late.click());
  const dlg = page.getByRole("dialog", { name: "Delivery · " + brand });
  await expect(dlg).toContainText("late");
  await rerun(page, () => dlg.getByRole("button", { name: "Move date…" }).click());
  const move = page.getByRole("dialog", { name: `Move the ${brand} delivery` });
  await expect(move).toBeVisible();
  // Esc closes only the nested one, and the app knows (onDismiss)
  await rerun(page, () => page.keyboard.press("Escape"));
  await expect(move).toHaveCount(0);
  await expect(dlg).toBeVisible();
  await rerun(page, () => dlg.getByRole("button", { name: "Mark delivered" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  if (lateBefore > 1) await expect(badge).toHaveText(String(lateBefore - 1));
  else await expect(badge).toHaveCount(0);
  // day scale, then a click on an empty day of Gizmo
  await rerun(page, () => page.getByRole("radiogroup", { name: "Scale" }).getByRole("button", { name: "day" }).click());
  // the grid starts 4 weeks before today (Oct 21): day 50 is Dec 10
  await rerun(page, () => grid.locator('tr[data-row="b9"] td.cal-cell').nth(50).click({ position: { x: 3, y: 3 } }));
  const plan = page.getByRole("dialog", { name: "Plan a delivery · Gizmo" });
  await expect(plan).toBeVisible();
  await rerun(page, () => plan.getByRole("button", { name: "Plan it" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByText("Planned: Gizmo on 2026-12-10")).toBeVisible();
});

test("import: upload, match supplier names, review, apply", async ({ page }) => {
  await open(page, "planning", "/import");
  const csv = "supplier,brand,month,amount\nACME Corporation,Rocket,12,2400\nNew Co,Thing,12,100\nGlobex,Gizmo,3,1\n";
  await rerun(page, () => page.locator('input[type="file"]').setInputFiles({ name: "plan.csv", mimeType: "text/csv", buffer: Buffer.from(csv) }));
  await expect(page.getByText("plan.csv: 3 rows, 3 suppliers.")).toBeVisible();
  // the guess for "ACME Corporation" is ACME; "New Co" becomes a new supplier
  await expect(page.getByRole("combobox", { name: "“ACME Corporation” is" })).toHaveValue("ACME");
  await expect(page.getByRole("combobox", { name: "“New Co” is" })).toHaveValue("+ New supplier");
  await rerun(page, () => page.getByRole("button", { name: "Next" }).click());
  const t = page.getByTestId("st-dataframe");
  await expect(t.locator("tbody tr")).toHaveCount(3);
  await expect(t.locator("tbody tr", { hasText: "Gizmo" })).toContainText("closed month");
  await expect(t.locator("tbody tr", { hasText: "Thing" }).locator("td").first()).toHaveClass(/cs-bg-success/);
  await rerun(page, () => page.getByRole("button", { name: "Apply" }).click());
  await expect(page.getByText("Imported 2 plan cells.")).toBeVisible();
  // the plan has the new supplier's brand now
  await open(page, "planning");
  const ed = page.getByTestId("st-data-editor");
  await expect(ed.getByLabel("Brand row 7")).toHaveValue("Thing");
  await expect(ed.getByLabel("Dec row 7")).toHaveValue("100");
});

test("import: a broken file is explained", async ({ page }) => {
  await open(page, "planning", "/import");
  await rerun(page, () => page.locator('input[type="file"]').setInputFiles({ name: "x.csv", mimeType: "text/csv", buffer: Buffer.from("a,b\n1,2\n") }));
  await expect(page.getByText('The column "supplier" is missing.')).toBeVisible();
});
