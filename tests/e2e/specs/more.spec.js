// streamlitd's extra elements (examples/widgets, tab "More"): card, stepper, skeleton, timeline,
// avatar, details, tags, tree select, date range, copy button.
const { test } = require("@playwright/test");
const { open, rerun, expect, widget } = require("./helpers");

async function openMore(page) {
  await open(page, "widgets");
  await page.getByRole("tab", { name: "More" }).click();
}
const summary = (page) => page.getByText(/^Tags:/);

test("display elements: cards, stepper, skeleton, timeline, avatars, details", async ({ page }) => {
  await openMore(page);
  const cards = page.getByTestId("st-card");
  await expect(cards).toHaveCount(3);
  await expect(cards.first().locator(".card-title")).toHaveText(/Revenue/);
  await expect(cards.first().locator(".card-subtitle")).toHaveText("Last 30 days");
  await expect(cards.nth(1).getByRole("button", { name: "Open Orders" })).toBeVisible();
  // stepper driven by session state
  const stepper = page.getByTestId("st-stepper");
  await expect(stepper.locator('[aria-current="step"]')).toContainText("Account");
  await rerun(page, () => page.getByRole("button", { name: "Next" }).click());
  await expect(stepper.locator('[aria-current="step"]')).toContainText("Address");
  await expect(stepper.locator(".step.done")).toHaveCount(1);
  await rerun(page, () => page.getByRole("button", { name: "Back" }).click());
  await expect(stepper.locator(".step.done")).toHaveCount(0);
  await expect(page.getByTestId("st-skeleton")).toHaveAttribute("role", "status");
  const tl = page.getByTestId("st-timeline").locator("li");
  await expect(tl).toHaveCount(4);
  await expect(tl.nth(2)).toHaveClass(/tl-warning/);
  await expect(tl.first()).toContainText("Order #1042, 3 items");
  await expect(page.getByRole("img", { name: "Ann Lee" })).toHaveText("AL");
  const det = page.getByTestId("st-details");
  await expect(det.locator("dt")).toHaveText(["Customer", "Contact", "Since", "Status"]);
  await expect(det.locator("dd").last()).toHaveText("Active");
});

test("tags input: Enter, comma, suggestions, Backspace", async ({ page }) => {
  await openMore(page);
  const box = widget(page, "tags_input", "Tags");
  const input = box.getByRole("combobox");
  await expect(box.locator(".chip")).toHaveText(["d×", "dashboard×"]);
  await rerun(page, async () => { await input.fill("charts"); await input.press("Enter"); });
  await expect(summary(page)).toContainText("Tags: d, dashboard, charts");
  await rerun(page, () => input.pressSequentially("ops,"));
  await expect(summary(page)).toContainText("charts, ops");
  // suggestions: those not picked yet, filtered by the typed text
  await input.fill("vi");
  await expect(page.locator("#stPopups .st-option")).toHaveText(["vibe.d"]);
  await input.press("ArrowDown");
  await rerun(page, () => input.press("Enter"));
  await expect(summary(page)).toContainText("ops, vibe.d");
  await rerun(page, () => input.press("Backspace"));
  await expect(summary(page)).not.toContainText("vibe.d");
  await rerun(page, () => box.getByRole("button", { name: "Remove d", exact: true }).click());
  await expect(summary(page)).toContainText("Tags: dashboard, charts, ops");
});

test("tree select: subtree checks, search, keyboard, commit on close", async ({ page }) => {
  await openMore(page);
  const field = page.getByRole("button", { name: /^Regions:/ });
  await expect(field).toContainText("Germany");
  await field.click();
  const tree = page.getByRole("tree");
  await expect(tree.getByRole("treeitem", { name: "Europe" })).toHaveAttribute("aria-checked", "mixed");
  // checking a parent checks its subtree; nothing is sent until the popup closes
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  await tree.getByRole("treeitem", { name: "Americas" }).click();
  await expect(tree.getByRole("treeitem", { name: "Americas" })).toHaveAttribute("aria-checked", "true");
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs);
  // search shows matches with their parents, opened
  await page.getByRole("textbox", { name: /Search/ }).fill("jap");
  await expect(tree.getByRole("treeitem")).toHaveText([/Asia/, /Japan/]);
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press(" ");
  await expect(tree.getByRole("treeitem", { name: "Asia" })).toHaveAttribute("aria-checked", "true"); // its only child
  await rerun(page, () => page.getByRole("button", { name: "Done" }).click());
  await expect(summary(page)).toContainText("Regions: de, am, us, br, as, jp"); // tree order
  await expect(field).toContainText("Germany, Americas, Asia"); // the top-most picked nodes
  // Clear
  await field.click();
  await page.getByRole("button", { name: "Clear" }).click();
  await rerun(page, () => page.keyboard.press("Escape"));
  await expect(summary(page)).toContainText(/Regions:\s+· Period/);
  await expect(field).toContainText("Choose");
});

test("date range: two clicks in the calendar, typed range", async ({ page }) => {
  await openMore(page);
  const box = widget(page, "date_range_input", "Period");
  const input = box.getByRole("textbox");
  await expect(input).toHaveValue("2026-01-01 – 2026-01-31");
  await box.getByRole("button", { name: "Open calendar" }).click();
  const cal = page.locator("#stPopups");
  await expect(cal.getByText("Pick the start date")).toBeVisible();
  await expect(cal.locator(".st-cal-day.in-range")).toHaveCount(29);
  await cal.locator('[data-date="2026-01-20"]').click();
  await expect(cal.getByText("Pick the end date")).toBeVisible();
  await rerun(page, () => cal.locator('[data-date="2026-01-05"]').click()); // before the start: swapped
  await expect(summary(page)).toContainText("Period: 2026-01-05 – 2026-01-20");
  await rerun(page, async () => { await input.fill("2026-02-10 - 2026-02-01"); await input.press("Enter"); });
  await expect(summary(page)).toContainText("Period: 2026-02-01 – 2026-02-10");
});

test("copy button copies without a rerun", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await openMore(page);
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  const b = page.getByTestId("st-copy-button");
  await b.click();
  await expect(b).toContainText("Copied ✓");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe("https://example.com/report?period=2026-01-01");
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs);
  await expect(b).toContainText("Copy report link", { timeout: 3000 });
});
