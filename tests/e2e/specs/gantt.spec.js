// examples/gantt (today fixed to 2026-11-18): a Gantt chart on st.calendarGrid with phases, spans,
// milestones and status colours; edit and add dialogs (a nested delete confirmation); dependency
// warnings; a table view with a CSV export.
const { test } = require("@playwright/test");
const { open, rerun, pick, expect } = require("./helpers");

// one shared project: the tests change it one after another
test.describe.configure({ mode: "serial" });

const grid = (page) => page.getByTestId("st-calendar-grid");

test("chart: phases, bars coloured by status, milestones, a scheduling problem", async ({ page }) => {
  await open(page, "gantt");
  await expect(page.getByText("1 scheduling problem")).toBeVisible();
  await expect(page.getByText(/Visual design starts .*, before Wireframes ends/)).toBeVisible();
  const g = grid(page);
  await expect(g.locator('[data-item="t7"]').first()).toHaveAttribute("aria-label", /Content migration · Chen · late/);
  await expect(g.locator('[data-item="t3"]')).toHaveAttribute("aria-label", /Requirements signed off · Ann · done/);
  await expect(g.locator(".cal-progress").first()).toHaveAttribute("aria-label", "100%, expected 100%"); // Discovery
  await expect(page.getByTestId("st-sidebar").getByRole("link", { name: /Tasks/ }).locator(".nav-badge")).toHaveText("1");
});

test("edit a task's dates in the dialog: the problem is solved", async ({ page }) => {
  await open(page, "gantt");
  await rerun(page, () => grid(page).locator('[data-item="t5"]').first().click());
  const dlg = page.getByRole("dialog", { name: "Edit task" });
  await expect(dlg.getByText(/Starts before “Wireframes” ends/)).toBeVisible();
  // the dates as a range: Nov 14 – Nov 23
  const range = dlg.getByRole("textbox", { name: "Dates" });
  await range.fill("2026-11-14 – 2026-11-23");
  await rerun(page, () => range.press("Enter"));
  await expect(dlg.getByText(/Starts before “Wireframes” ends/)).toHaveCount(0);
  await rerun(page, () => dlg.getByRole("button", { name: "Save" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  // the downstream tasks now start too early: listed
  await expect(page.getByText("2 scheduling problems")).toBeVisible();
  await expect(page.getByText(/Frontend starts .*, before Visual design ends/)).toBeVisible();
});

test("click an empty day: add a task there; delete it with a nested confirmation", async ({ page }) => {
  await open(page, "gantt");
  await rerun(page, () => page.getByRole("radiogroup", { name: "Scale" }).getByRole("button", { name: "day" }).click());
  const g = grid(page);
  const cells = g.locator('tr[data-row="t9"] td.cal-cell');
  // the chart starts 3 days before the project (Oct 25): Dec 1 is day 40
  await rerun(page, () => cells.nth(40).click({ position: { x: 2, y: 2 } }));
  const dlg = page.getByRole("dialog", { name: "New task" });
  await expect(dlg.getByRole("combobox", { name: "Phase" })).toHaveValue("Build");
  await dlg.getByLabel("Name").fill("Accessibility check");
  await rerun(page, () => dlg.getByLabel("Name").press("Tab"));
  await rerun(page, () => pick(page, dlg.getByRole("combobox", { name: "Assignee" }), "Dana"));
  await rerun(page, () => dlg.getByRole("button", { name: "Add" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  const added = g.locator('[data-item][aria-label^="Accessibility check · Dana"]').first();
  await expect(added).toBeVisible();
  await rerun(page, () => added.click());
  await rerun(page, () => page.getByRole("dialog", { name: "Edit task" }).getByRole("button", { name: "Delete…" }).click());
  const confirm = page.getByRole("dialog", { name: "Delete “Accessibility check”?" });
  await expect(page.getByRole("dialog")).toHaveCount(2);
  await rerun(page, () => confirm.getByRole("button", { name: "Delete" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(g.locator('[data-item][aria-label^="Accessibility check"]')).toHaveCount(0);
});

test("milestones: a progress checkbox instead of a slider", async ({ page }) => {
  await open(page, "gantt");
  await rerun(page, () => grid(page).locator('[data-item="t6"]').click()); // Design review
  const dlg = page.getByRole("dialog", { name: "Edit task" });
  await expect(dlg.getByRole("checkbox", { name: "Milestone (one day)" })).toBeChecked();
  await expect(dlg.getByText("Reached")).toBeVisible();
  await expect(dlg.getByRole("slider")).toHaveCount(0);
  await rerun(page, () => page.keyboard.press("Escape"));
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("table: grouped by phase, late tasks marked, a click edits, the export", async ({ page }) => {
  await open(page, "gantt", "/tasks");
  const t = page.getByTestId("st-dataframe");
  await expect(t.locator("tr.tree-group")).toHaveCount(4);
  await expect(t.locator("tr", { hasText: "Content migration" }).locator("td.cs-bg-error")).toHaveText("late");
  await rerun(page, () => t.locator("tr", { hasText: /^\s*Backend API/ }).click()); // not the row that depends on it
  const dlg = page.getByRole("dialog", { name: "Edit task" });
  await expect(dlg.getByLabel("Name")).toHaveValue("Backend API");
  await rerun(page, () => page.keyboard.press("Escape"));
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByRole("dialog")).toHaveCount(0); // stays closed though the row is still selected
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: /Export CSV/ }).click();
  const text = require("fs").readFileSync(await (await dl).path(), "utf8");
  expect(text.split("\n")[0]).toBe("phase,task,start,end,days,progress,assignee,status,after");
});

test("the date pickers offer only dates the project can hold", async ({ page }) => {
  await open(page, "gantt");
  await rerun(page, () => grid(page).locator('[data-item="t9"]').first().click());
  const dlg = page.getByRole("dialog", { name: "Edit task" });
  const range = dlg.getByRole("textbox", { name: "Dates" });
  await range.fill("2026-12-01 – 9999-12-31");
  await range.press("Enter");
  await page.waitForTimeout(300);
  await expect(range).not.toHaveValue(/9999/); // the picker keeps to its bounds
  await rerun(page, () => dlg.getByRole("button", { name: "Save" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  // still a drawable task, and the chart still draws
  await expect(grid(page).locator('[data-item="t9"]').first()).toHaveAttribute("aria-label", /Backend API/);
  await expect(page.getByTestId("st-exception")).toHaveCount(0);
});
