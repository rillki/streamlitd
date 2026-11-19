// examples/business: folding sidebar sections with badges, link cards, a required segmented control,
// KPI trends, a tree table, a downloaded file built on click, the feed, and st.context.
const { test } = require("@playwright/test");
const { open, rerun, url, waitIdle, expect } = require("./helpers");

test("sidebar sections fold, carry badges, and open on the current page", async ({ page }) => {
  await open(page, "business");
  const nav = page.getByTestId("st-sidebar");
  const purchasing = nav.getByRole("button", { name: /Purchasing/ });
  await expect(purchasing).toHaveAttribute("aria-expanded", "false");
  await expect(purchasing.locator(".nav-badge")).toHaveText("2"); // unread count of its pages while folded
  await purchasing.click();
  await expect(purchasing).toHaveAttribute("aria-expanded", "true");
  await expect(nav.getByRole("link", { name: /Inbox/ }).locator(".nav-badge")).toHaveText("2");
  await rerun(page, () => nav.getByRole("link", { name: /Inbox/ }).click());
  await expect(page.locator("h1")).toContainText("Inbox");
  await expect(nav.getByRole("button", { name: /Purchasing/ })).toHaveAttribute("aria-expanded", "true"); // current section
});

test("overview: required segmented control, KPI trends, proportion bar, link cards", async ({ page }) => {
  await open(page, "business");
  const period = page.getByRole("radiogroup", { name: "Period" });
  // clicking the selected option keeps it (no rerun, still selected)
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  await period.getByRole("button", { name: "Month" }).click();
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs);
  await expect(period.getByRole("button", { name: "Month" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByTestId("st-metric").first().getByRole("img", { name: /Trend from 4.8 to 5.51/ })).toBeVisible();
  await expect(page.getByText("was 5,288 € last Month")).toBeVisible();
  await expect(page.getByTestId("st-proportion-bar")).toContainText("Overdue 1,135 € · 31%");
  // the whole card is a link to its page
  await rerun(page, () => page.getByTestId("st-card-link").first().click());
  await expect(page.locator("h1")).toContainText("Suppliers");
  await expect(page).toHaveURL(/\/suppliers$/);
});

test("suppliers: tree with grouped headers and colours; the export is built on click", async ({ page }) => {
  await open(page, "business", "/suppliers");
  const t = page.getByTestId("st-dataframe");
  await expect(t.locator("thead tr.group-row th.named")).toHaveText(["Purchases, €", "Payments"]);
  await expect(t.locator("tr.tree-group", { hasText: "Bob" })).toContainText("2,160");
  await t.locator("tr.tree-group", { hasText: "Initech" }).getByRole("button", { name: "Expand Initech" }).click();
  await expect(t.locator("tr", { hasText: "Printer" }).locator("td").last()).toHaveClass(/cs-bg-error/);
  await expect(page.getByTestId("st-legend")).toContainText("Overdue more than 14 days");
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: /Download CSV/ }).click();
  const file = await dl;
  expect(file.suggestedFilename()).toBe("suppliers.csv");
  const text = require("fs").readFileSync(await file.path(), "utf8");
  expect(text.split("\n")[0]).toContain("manager,supplier,brand");
});

test("inbox: feed with unread items, pagination, and the request context", async ({ page }) => {
  await open(page, "business", "/inbox");
  const feed = page.getByTestId("st-feed");
  await expect(feed.locator(".feed-item.unread")).toHaveCount(2);
  await rerun(page, () => page.getByRole("radiogroup", { name: "Show" }).getByRole("button", { name: "All" }).click());
  await expect(feed.locator(".feed-item")).toHaveCount(3); // 4 items, 3 per page
  await rerun(page, () => page.getByRole("button", { name: "Next page" }).click());
  await expect(feed.locator(".feed-item")).toHaveCount(1);
  await page.goto(url("business", "/about"));
  await waitIdle(page, 1);
  const d = page.getByTestId("st-details");
  // the time zone and language come from the browser, the address and user agent from the request
  await expect(d).toContainText(await page.evaluate(() => Intl.DateTimeFormat().resolvedOptions().timeZone));
  await expect(d).toContainText("127.0.0.1");
  await expect(d).toContainText("Mozilla");
});

test("calendar grid: focus link, keyboard between items, rows fold, clicks reach the app", async ({ page }) => {
  await open(page, "business", "/order-plan?focus=d3");
  const grid = page.getByTestId("st-calendar-grid");
  await expect(grid.locator("th.cal-day.today")).toHaveText("18");
  await expect(grid.locator("th.cal-day.today")).toHaveAttribute("aria-current", "date");
  await expect(grid.locator('[data-item="d3"]')).toHaveClass(/pulse/);    // ?focus=d3: scrolled to and highlighted
  await expect(grid.locator('[data-item="d3"]')).toBeInViewport();
  // keyboard: → along the row, ↓ to the nearest item in the next row
  await grid.locator('[data-item="d1"]').focus();
  await page.keyboard.press("ArrowRight");
  await expect(grid.locator('[data-item="d2"]')).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(grid.locator('.cal-span[data-item="p1"]').first()).toBeFocused();
  // rows fold
  await grid.getByRole("button", { name: "Collapse ACME" }).click();
  await expect(grid.locator('tr[data-row="rocket"]')).toHaveCount(0);
  await grid.getByRole("button", { name: "Expand ACME" }).click();
  // an empty day reaches the app as a cell event
  await rerun(page, () => grid.locator('tr[data-row="anvil"] td.cal-cell').nth(3).click({ position: { x: 3, y: 3 } }));
  await expect(page.getByTestId("st-toasts")).toContainText("Add a delivery for anvil on 2026-11-04");
});

test("nested dialogs: a dialog opened from a dialog sits on top; Esc closes only the top one", async ({ page }) => {
  await open(page, "business", "/order-plan");
  await rerun(page, () => page.locator('[data-item="d3"]').click());
  const outer = page.getByRole("dialog", { name: "Delivery d3" });
  await expect(outer).toBeVisible();
  await rerun(page, () => outer.getByRole("button", { name: "Change date" }).click());
  const inner = page.getByRole("dialog", { name: "Change date of d3" });
  await expect(inner).toBeVisible();
  // the inner one is on top: clicks reach it
  await expect(inner.getByRole("button", { name: "Save" })).toBeEnabled();
  // Esc closes the top one; the app hears of it (onDismiss) and reruns with the outer one still open
  await rerun(page, () => page.keyboard.press("Escape"));
  await expect(inner).toHaveCount(0);
  await expect(outer).toBeVisible();
  await rerun(page, () => page.keyboard.press("Escape"));
  await expect(outer).toHaveCount(0);
  // a later rerun doesn't open it again
  await rerun(page, () => page.keyboard.press("r")); // the rerun shortcut
  await expect(page.getByRole("dialog", { name: "Delivery d3" })).toHaveCount(0);
});
