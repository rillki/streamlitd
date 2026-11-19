// examples/todo (today fixed to 2026-11-18): sign-up with automatic hashing, lists per person, quick
// add, done checkboxes, filters, bulk actions with a confirmation, edit dialogs, live tabs.
// Every test signs up its own user, so the tests don't share tasks.
const { test } = require("@playwright/test");
const { url, rerun, waitIdle, pick, expect } = require("./helpers");

let n = 0;
async function signUp(page, p = "/") {
  const user = `u${Date.now().toString(36)}${n++}${Math.floor(Math.random() * 1000)}`;
  await page.goto(url("todo", "/auth/register"));
  await page.getByLabel("Username").fill(user);
  await page.getByLabel("Password", { exact: true }).fill("streamlitd-demo");
  await page.getByLabel("Repeat the password").fill("streamlitd-demo");
  await page.getByRole("button", { name: "Create account" }).click();
  await expect(page).not.toHaveURL(/\/auth\//);
  await waitIdle(page, 1);
  if (p !== "/") { await page.goto(url("todo", p)); await waitIdle(page, 1); }
  return user;
}

const task = (page, title) => page.getByRole("checkbox", { name: title, exact: true });

test("sign up, then the starter lists with badges", async ({ page }) => {
  await signUp(page);
  await expect(page.locator("h1")).toContainText("Today");
  const nav = page.getByTestId("st-sidebar");
  await expect(nav.getByRole("link", { name: /Today/ }).locator(".nav-badge")).toHaveText("4");
  await expect(nav.getByRole("link", { name: /Work/ }).locator(".nav-badge")).toHaveText("4");
  // overdue in red, priority and tags as badges
  await expect(page.getByText("🗓️ yesterday")).toHaveClass(/st-color-red/);
  await expect(page.locator(".badge", { hasText: "#reports" }).first()).toBeVisible();
});

test("quick add with #tags, !priority and ^due; tick it off", async ({ page }) => {
  await signUp(page, "/list-work");
  const input = page.getByRole("textbox", { name: "New task" });
  await input.fill("Write release notes #docs !high ^tomorrow");
  await rerun(page, () => input.press("Enter"));
  await expect(task(page, "Write release notes")).toBeVisible();
  await expect(input).toHaveValue(""); // the form clears itself
  await expect(input).toBeFocused(); // and typing can go on
  await expect(page.locator(".badge", { hasText: "#docs" })).toBeVisible();
  await expect(page.getByText("🗓️ tomorrow").first()).toBeVisible();
  await rerun(page, () => page.getByText("Write release notes", { exact: true }).click());
  await expect(task(page, "Write release notes")).toHaveCount(0); // "Open" hides done tasks
  await rerun(page, () => page.getByRole("radiogroup", { name: "Show" }).getByRole("button", { name: "Done" }).click());
  await expect(page.getByRole("checkbox", { name: "Write release notes" })).toBeChecked();
});

test("filters: tags, search, empty state", async ({ page }) => {
  await signUp(page, "/list-work");
  await rerun(page, () => page.getByRole("group", { name: "Tags" }).getByRole("button", { name: "reports" }).click());
  await expect(page.getByRole("checkbox")).toHaveCount(2);
  await page.getByRole("textbox", { name: "Search", exact: true }).fill("nothing like this");
  await rerun(page, () => page.getByRole("textbox", { name: "Search", exact: true }).press("Enter"));
  await expect(page.getByTestId("st-empty-state")).toContainText("No tasks match");
});

test("edit dialog: change the title and priority; delete with a nested confirmation", async ({ page }) => {
  await signUp(page, "/list-home");
  await rerun(page, () => page.getByRole("button", { name: "Edit" }).first().click());
  const dlg = page.getByRole("dialog", { name: "Edit task" });
  await dlg.getByLabel("Title").fill("Buy groceries and flowers");
  await rerun(page, () => dlg.getByLabel("Title").press("Tab"));
  await rerun(page, () => dlg.getByRole("radiogroup", { name: "Priority" }).getByRole("button", { name: "high" }).click());
  await rerun(page, () => dlg.getByRole("button", { name: "Save" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(task(page, "Buy groceries and flowers")).toBeVisible();
  // delete it: the confirmation opens on top of the edit dialog
  // high priority and due today: the first task of the list now
  await rerun(page, () => page.getByRole("button", { name: "Edit" }).first().click());
  await rerun(page, () => page.getByRole("dialog", { name: "Edit task" }).getByRole("button", { name: "Delete…" }).click());
  const confirm = page.getByRole("dialog", { name: "Delete “Buy groceries and flowers”?" });
  await rerun(page, () => confirm.getByRole("button", { name: "Delete" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(task(page, "Buy groceries and flowers")).toHaveCount(0);
});

test("bulk: select rows, complete them, delete after a confirmation", async ({ page }) => {
  await signUp(page, "/list-work");
  await rerun(page, () => page.getByText("Select several").click());
  const t = page.getByTestId("st-dataframe");
  await expect(t.locator("tbody tr")).toHaveCount(4);
  await expect(t.locator("tbody tr").first().locator("td.cs-text-error")).toContainText("17.11.2026"); // overdue
  await rerun(page, () => t.getByLabel("Select row 0").check());
  await rerun(page, () => t.getByLabel("Select row 1").check());
  await expect(page.getByText("2 selected")).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "Complete" }).click());
  await expect(t.locator("tbody tr")).toHaveCount(2); // only open tasks are shown
  await rerun(page, () => t.getByLabel("Select row 0").check());
  await rerun(page, () => page.getByRole("button", { name: "Delete…" }).click());
  const confirm = page.getByRole("dialog", { name: "Delete 1 task?" });
  await rerun(page, () => confirm.getByRole("button", { name: "Delete" }).click());
  await expect(t.locator("tbody tr")).toHaveCount(1);
  await expect(page.getByTestId("st-sidebar").getByRole("link", { name: /Work/ }).locator(".nav-badge")).toHaveText("1");
});

test("a change in one tab shows up in the other tab of the same person", async ({ page, context }) => {
  await signUp(page, "/list-home");
  const other = await context.newPage(); // same browser, same login
  await other.goto(url("todo", "/list-home"));
  await waitIdle(other, 1);
  await rerun(page, () => page.getByText("Buy groceries", { exact: true }).click());
  await expect(task(other, "Buy groceries")).toHaveCount(0);
});

test("lists: add one, delete one after a confirmation", async ({ page }) => {
  await signUp(page, "/lists");
  await page.getByLabel("Name").fill("Garden");
  await rerun(page, () => page.getByRole("button", { name: "Add list" }).click());
  const nav = page.getByTestId("st-sidebar");
  await expect(nav.getByRole("link", { name: /Garden/ })).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "Delete" }).first().click()); // Work
  await rerun(page, () => page.getByRole("dialog", { name: "Delete “Work”?" }).getByRole("button", { name: "Delete the list" }).click());
  await expect(nav.getByRole("link", { name: /Work/ })).toHaveCount(0);
  await expect(nav.getByRole("link", { name: /Garden/ })).toBeVisible();
});

test("a title made of Markdown is shown as typed", async ({ page }) => {
  await signUp(page, "/list-work");
  const input = page.getByRole("textbox", { name: "New task" });
  await input.fill("![x](http://127.0.0.1:9/p.png) :red[boss] #a]b");
  await rerun(page, () => input.press("Enter"));
  await expect(page.getByText("![x](http://127.0.0.1:9/p.png) :red[boss]", { exact: true })).toBeVisible();
  await expect(page.locator("img[src*='127.0.0.1:9']")).toHaveCount(0);
  await expect(page.locator(".badge", { hasText: "#ab" })).toBeVisible(); // the tag keeps safe characters only
});
