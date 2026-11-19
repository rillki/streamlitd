// examples/helpdesk: a larger app — login with roles, a ticket table with selection, a detail panel,
// nested dialogs, live updates between agents, an API that updates open pages, roles in the navigation.
const { test } = require("@playwright/test");
const { url, rerun, waitIdle, pick, expect } = require("./helpers");

async function login(page, user, p = "/") {
  await page.goto(url("helpdesk", p));
  await expect(page).toHaveURL(/\/auth\/login/);
  await page.getByLabel("Username").fill(user);
  await page.getByLabel("Password").fill("streamlitd-demo");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).not.toHaveURL(/\/auth\/login/);
  await page.waitForLoadState("load");
  await waitIdle(page, 1);
}

const table = (page) => page.getByTestId("st-dataframe");
const row = (page, id) => table(page).locator("tbody tr", { hasText: id });

test("navigation: badges, and the users page only for admins", async ({ page, browser }) => {
  await login(page, "alice");
  const nav = page.getByTestId("st-sidebar");
  await expect(page.locator("h1")).toContainText("Dashboard");
  // the folded "Support" section shows the count of its pages' badges; opened, the page has its own
  const support = nav.getByRole("button", { name: /Support/ });
  await expect(support.locator(".nav-badge")).toHaveText(/^\d+$/);
  await support.click();
  await expect(nav.getByRole("link", { name: /Tickets/ }).locator(".nav-badge")).toHaveText(/^\d+$/);
  await expect(nav.getByRole("button", { name: /Settings/ })).toBeVisible();
  const ctx = await browser.newContext();
  const bob = await ctx.newPage();
  await login(bob, "bob");
  await expect(bob.getByTestId("st-sidebar").getByRole("button", { name: /Settings/ })).toHaveCount(0);
  await ctx.close();
});

test("select a ticket, change its status; another agent sees it at once", async ({ page, browser }) => {
  await login(page, "alice", "/tickets");
  const ctx = await browser.newContext();
  const other = await ctx.newPage();
  await login(other, "bob", "/tickets");
  await expect(row(other, "#0002")).toBeVisible();

  await rerun(page, () => row(page, "#0002").click());
  await expect(page.getByRole("heading", { name: /#0002/ })).toBeVisible();
  await rerun(page, () => pick(page, "Change status", "pending"));
  await rerun(page, () => page.getByRole("button", { name: "Save changes" }).click());
  await expect(row(page, "#0002")).toContainText("pending");
  // the other tab updates without a reload (the store pushes to every open session)
  await expect(row(other, "#0002")).toContainText("pending");
  await ctx.close();
});

test("edit dialog with a nested confirmation closes a ticket", async ({ page }) => {
  await login(page, "alice", "/tickets");
  // the last open ticket (other tests change the first ones)
  const last = table(page).locator("tbody tr").last();
  const id = (await last.locator("td").filter({ hasText: /^#\d{4}$/ }).first().textContent()).trim();
  await rerun(page, () => last.click());
  await rerun(page, () => page.getByRole("button", { name: "Edit…" }).click());
  const edit = page.getByRole("dialog", { name: "Edit " + id });
  await expect(edit).toBeVisible();
  await rerun(page, () => edit.getByRole("button", { name: "Close ticket…" }).click());
  const confirm = page.getByRole("dialog", { name: "Close " + id + "?" });
  await expect(confirm).toBeVisible();
  await rerun(page, () => confirm.getByRole("button", { name: "Yes, close it" }).click());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  // closed tickets leave the "active" list
  await expect(row(page, id)).toHaveCount(0);
});

test("a dialog closed with Esc stays closed on later reruns (onDismiss)", async ({ page }) => {
  await login(page, "alice", "/tickets");
  await rerun(page, () => row(page, "#0004").click());
  await rerun(page, () => page.getByRole("button", { name: "Edit…" }).click());
  await expect(page.getByRole("dialog", { name: "Edit #0004" })).toBeVisible();
  await rerun(page, () => page.keyboard.press("Escape")); // the app hears of it and reruns
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await rerun(page, () => pick(page, "Assignee", "nobody")); // another rerun of the page fragment
  await rerun(page, () => pick(page, "Assignee", "anyone"));
  await expect(page.getByRole("dialog")).toHaveCount(0);
});

test("comment form adds to the timeline", async ({ page }) => {
  await login(page, "bob", "/tickets");
  await rerun(page, () => row(page, "#0007").click());
  await page.getByLabel("Add a comment").fill("Called the customer, waiting for logs.");
  await rerun(page, () => page.getByRole("button", { name: "Comment" }).click());
  await expect(page.getByTestId("st-timeline")).toContainText("Called the customer, waiting for logs.");
  await expect(page.getByLabel("Add a comment")).toHaveValue("");
});

test("filters, empty state and the CSV export", async ({ page }) => {
  await login(page, "alice", "/tickets");
  await page.getByRole("textbox", { name: "Search", exact: true }).fill("no such thing");
  await rerun(page, () => page.getByRole("textbox", { name: "Search", exact: true }).press("Enter"));
  await expect(page.getByTestId("st-empty-state")).toContainText("No tickets match");
  await page.getByRole("textbox", { name: "Search", exact: true }).fill("");
  await rerun(page, () => page.getByRole("textbox", { name: "Search", exact: true }).press("Enter"));
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: /Export CSV/ }).click();
  const file = await dl;
  expect(file.suggestedFilename()).toBe("tickets.csv");
  const text = require("fs").readFileSync(await file.path(), "utf8");
  expect(text.split("\n")[0]).toBe("ticket,title,customer,priority,status,assignee");
});

test("API: agents post tickets, open pages show them; roles are enforced", async ({ page, playwright }) => {
  await login(page, "bob", "/tickets");
  const before = await page.request.get(url("helpdesk", "/api/tickets"));
  expect(before.ok()).toBe(true);
  const title = "From the API " + Date.now();
  const res = await page.request.post(url("helpdesk", "/api/tickets"), { data: { title, customer: "globex", priority: "high" } });
  expect(res.status()).toBe(201);
  // the open page picks it up without a reload
  await expect(table(page)).toContainText(title);
  // no cookie: refused
  const anon = await playwright.request.newContext();
  expect((await anon.get(url("helpdesk", "/api/tickets"))).status()).toBe(401);
  await anon.dispose();
});

test("customers: edits are checked before they are saved", async ({ page }) => {
  await login(page, "alice", "/customers");
  const ed = page.getByTestId("st-data-editor");
  const save = page.getByRole("button", { name: "Save", exact: true });
  await expect(save).toBeEnabled();
  await rerun(page, async () => { const c = ed.getByLabel(/email row 4/i); await c.fill("not-an-email"); await c.press("Enter"); });
  await expect(page.getByText('"not-an-email" is not an email address.')).toBeVisible();
  await expect(save).toBeDisabled();
  await rerun(page, async () => { const c = ed.getByLabel(/email row 4/i); await c.fill("team@hooli.example"); await c.press("Enter"); });
  await expect(save).toBeEnabled();
  await rerun(page, () => save.click());
  await expect(page.getByText("Saved 6 customers")).toBeVisible();
  // after a reload the saved value is there
  await page.reload();
  await waitIdle(page, 1);
  await expect(page.getByTestId("st-data-editor").getByLabel(/email row 4/i)).toHaveValue("team@hooli.example");
});

test("hostile API input is refused; typed Markdown stays text for everyone", async ({ page, browser }) => {
  await login(page, "bob", "/tickets");
  for (const [body, msg] of [
    [{ title: "x", priority: "apocalyptic" }, /priority/],
    [{ title: "x", customer: "no-such-customer" }, /unknown customer/],
    [{ title: "x".repeat(201) }, /longer/],
    [{ title: 42 }, /must be a string/],
    [[1, 2], /JSON object/],
  ]) {
    const res = await page.request.post(url("helpdesk", "/api/tickets"), { data: body });
    expect(res.status(), JSON.stringify(body).slice(0, 40)).toBe(400);
    expect(await res.text()).toMatch(msg);
  }
  // a ticket titled with an image: another agent's browser must not load anything
  const title = "![pixel](http://127.0.0.1:9/p.png) :red[urgent] " + Date.now();
  expect((await page.request.post(url("helpdesk", "/api/tickets"), { data: { title, priority: "high" } })).status()).toBe(201);
  const ctx = await browser.newContext();
  const other = await ctx.newPage();
  const fetched = [];
  other.on("request", (r) => { if (r.url().includes("127.0.0.1:9")) fetched.push(r.url()); });
  await login(other, "alice", "/");
  await expect(other.getByTestId("st-feed")).toContainText("![pixel](http://127.0.0.1:9/p.png) :red[urgent]");
  await expect(other.locator("img[src*='127.0.0.1:9']")).toHaveCount(0);
  expect(fetched).toEqual([]);
  await ctx.close();
});
