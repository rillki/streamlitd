const { test } = require("@playwright/test");
const { open, rerun, widget, expect } = require("./helpers");

const fullRuns = async (page) => +(await page.getByText(/^full runs: \d+/).textContent()).match(/\d+/)[0];

test("fragment widget reruns only the fragment", async ({ page }) => {
  await open(page, "fragments");
  const before = await fullRuns(page);
  await rerun(page, async () => {
    const s = widget(page, "slider", "Inner value (reruns only this box)").locator("input[type=range]");
    await s.focus();
    await s.press("End");
  });
  await expect(page.getByText(/^inner result: 100 /)).toBeVisible();
  expect(await fullRuns(page)).toBe(before);
  // outer widget reruns everything and the fragment sees the new outer value
  await rerun(page, async () => {
    const s = widget(page, "slider", "Outer factor (reruns everything)").locator("input[type=range]");
    await s.focus();
    await s.press("End");
  });
  await expect(page.getByText(/^inner result: 500 /)).toBeVisible();
  expect(await fullRuns(page)).toBe(before + 1);
});

test("runEvery fragment refreshes by itself", async ({ page }) => {
  await open(page, "fragments");
  const ticks = page.getByTestId("st-metric").filter({ hasText: "Ticks" }).locator(".metric-value");
  const t0 = +(await ticks.textContent());
  const runs0 = await fullRuns(page);
  await expect.poll(async () => +(await ticks.textContent()), { timeout: 5000 }).toBeGreaterThan(t0 + 2);
  expect(await fullRuns(page)).toBe(runs0);
});

test("dialog opens, reruns inside, saves and closes", async ({ page }) => {
  await open(page, "fragments");
  await rerun(page, () => page.getByRole("button", { name: "Edit profile" }).click());
  const dlg = page.getByRole("dialog", { name: "Edit profile" });
  await expect(dlg).toBeVisible();
  const before = await fullRuns(page);
  await rerun(page, async () => { const i = dlg.getByLabel("Display name"); await i.fill("Bob"); await i.press("Enter"); });
  await expect(dlg.getByText("preview: Bob")).toBeVisible();
  expect(await fullRuns(page)).toBe(before);
  await dlg.getByRole("button", { name: "Save" }).click();
  await expect(dlg).toBeHidden();
  await expect(page.getByText("Saved name: Bob")).toBeVisible();
  // dismiss with Escape
  await rerun(page, () => page.getByRole("button", { name: "Edit profile" }).click());
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toBeHidden();
});

test("status container updates in place", async ({ page }) => {
  await open(page, "fragments");
  await rerun(page, () => page.getByRole("button", { name: "Run job" }).click());
  const st = page.getByTestId("st-status-container");
  await expect(st).toContainText("Job complete");
  await expect(st).toHaveAttribute("data-state", "complete");
  await st.locator("summary").click();
  await expect(st.getByText("Parsed rows")).toBeVisible();
});

test("pills, segmented control, feedback, link button, badge", async ({ page }) => {
  await open(page, "fragments");
  const out = page.getByText(/^size=/);
  await expect(out).toHaveText("size=- days=[\"Mon\"] view=Table rating=-1 thumbs=-1");
  await rerun(page, () => page.getByRole("button", { name: "L", exact: true }).click());
  await rerun(page, () => page.getByRole("button", { name: "Wed" }).click());
  await rerun(page, () => page.getByRole("button", { name: "Chart" }).click());
  await rerun(page, () => page.getByRole("button", { name: "stars 4" }).click());
  await rerun(page, () => page.getByRole("button", { name: "thumbs 2" }).click());
  await expect(out).toHaveText("size=L days=[\"Mon\", \"Wed\"] view=Chart rating=3 thumbs=1");
  await rerun(page, () => page.getByRole("button", { name: "L", exact: true }).click()); // deselect
  await expect(out).toContainText("size=-");
  await expect(page.getByTestId("st-link-button")).toHaveAttribute("href", "https://dlang.org");
  await expect(page.getByTestId("st-badge")).toHaveText(/Beta/);
});
