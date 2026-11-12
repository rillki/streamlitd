// Accounts (examples/accounts): sign-up without manual hashes, the first account is admin,
// invites, roles, disabling, the account page and login throttling. The tests build on each
// other (one user store per run), so they run in order.
const { test } = require("@playwright/test");
const { url, waitIdle, rerun, widget, pick, expect } = require("./helpers");

test.describe.configure({ mode: "serial" });

const root = { user: "root", name: "Root Admin", pw: "blue horse 7" };
const mia = { user: "mia", name: "Mia Lane", pw: "green tree 42" };

async function login(page, u, pw) {
  await page.goto(url("accounts", "/auth/login"));
  await page.getByLabel("Username").fill(u);
  await page.getByLabel("Password", { exact: true }).fill(pw);
  await page.getByRole("button", { name: "Sign in" }).click();
  await waitIdle(page, 1);
}

async function register(page, u, path = "/auth/register") {
  await page.goto(url("accounts", path));
  await page.getByLabel("Username").fill(u.user);
  await page.getByLabel("Full name").fill(u.name);
  await page.getByLabel("Password", { exact: true }).fill(u.pw);
  await page.getByLabel("Repeat the password").fill(u.pw);
  await page.getByRole("button", { name: "Create account" }).click();
}

test("the first sign-up becomes the administrator (no hashes to make)", async ({ page }) => {
  await page.goto(url("accounts", "/"));
  await expect(page).toHaveURL(/\/auth\/login$/);
  await page.getByTestId("register-link").click();
  await expect(page.getByTestId("first-admin-note")).toBeVisible();
  await expect(page.getByLabel("Invite code")).toHaveCount(0); // the first account needs no invite
  await register(page, root);
  await waitIdle(page, 1);
  await expect(page.locator("h1")).toContainText("Welcome, Root Admin");
  await expect(page.getByText("Roles: admin.")).toBeVisible();
  await expect(page.getByTestId("st-top-nav").getByText("Admin")).toBeVisible();
  // sign-up is now by invite only
  await page.goto(url("accounts", "/auth/register"));
  await expect(page.getByLabel("Invite code")).toBeVisible();
  await expect(page.getByTestId("first-admin-note")).toHaveCount(0);
});

test("invites, roles and disabling (they apply at once)", async ({ page, browser }) => {
  await login(page, root.user, root.pw);
  await page.goto(url("accounts", "/admin"));
  await waitIdle(page, 1);
  await page.getByRole("tab", { name: "Invites" }).click();
  await rerun(page, () => page.getByRole("button", { name: "Create invite" }).click());
  const link = (await page.locator("pre").filter({ hasText: "/auth/register?invite=" }).innerText()).trim();

  // a colleague signs up with the invite (prefilled from the link)
  const other = await browser.newContext();
  const p2 = await other.newPage();
  await p2.goto(url("accounts", link));
  await expect(p2.getByLabel("Invite code")).not.toHaveValue("");
  await register(p2, mia, link);
  await waitIdle(p2, 1);
  await expect(p2.locator("h1")).toContainText("Welcome, Mia Lane");
  await expect(p2.getByTestId("st-top-nav").getByText("Admin")).toHaveCount(0);
  await p2.goto(url("accounts", "/reports"));
  await waitIdle(p2, 1);
  await expect(p2.getByRole("alert")).toContainText("You need the editor role");
  expect((await p2.request.get(url("accounts", "/api/users"))).status()).toBe(403);
  // the invite worked once
  const p3 = await (await browser.newContext()).newPage();
  await register(p3, { user: "eve", name: "Eve", pw: "orange cat 3" }, link);
  await expect(p3.getByRole("alert")).toContainText("This invite is not valid");

  // the admin gives mia the editor role (after a reload: the panel was drawn before she signed up)
  await page.reload();
  await waitIdle(page, 1);
  await rerun(page, () => pick(page, "Manage user", "mia"));
  const roles = page.locator('[data-testid="st-tags_input"][data-label="Roles"]:visible').getByRole("combobox");
  await roles.fill("editor");
  await rerun(page, () => roles.press("Enter"));
  await roles.press("Escape"); // close the role suggestions
  await rerun(page, () => page.getByRole("button", { name: "Save roles" }).click());
  await p2.reload();
  await waitIdle(p2, 1);
  await expect(p2.locator("h1")).toContainText("Reports");
  const api = await page.request.get(url("accounts", "/api/users"));
  expect(await api.json()).toEqual({ users: ["root", "mia"] });

  // disabling ends mia's login
  await rerun(page, () => page.getByRole("button", { name: "Disable" }).click());
  await p2.reload();
  await expect(p2).toHaveURL(/\/auth\/login/);
  await p2.getByLabel("Username").fill(mia.user);
  await p2.getByLabel("Password", { exact: true }).fill(mia.pw);
  await p2.getByRole("button", { name: "Sign in" }).click();
  await expect(p2.getByRole("alert")).toHaveText("This account is disabled.");
  await other.close();
});

test("account settings: change the password from the user menu", async ({ page }) => {
  await login(page, root.user, root.pw);
  await page.getByTestId("st-user-menu").click();
  await page.getByRole("menuitem", { name: "Account settings" }).click();
  await expect(page).toHaveURL(/\/auth\/account$/);
  await page.getByLabel("Current password").fill(root.pw);
  await page.getByLabel("New password", { exact: true }).fill("red river 99");
  await page.getByLabel("Repeat the new password").fill("red river 99");
  await page.getByRole("button", { name: "Change password" }).click();
  await expect(page.getByRole("status")).toContainText("Your password was changed");
  await page.getByRole("link", { name: "Log out" }).click();
  await login(page, root.user, "red river 99");
  await expect(page.locator("h1")).toContainText("Welcome");
  root.pw = "red river 99";
});

test("repeated wrong passwords lock the login for a while", async ({ page }) => {
  await page.goto(url("accounts", "/auth/login"));
  for (let i = 0; i < 5; i++) {
    await page.getByLabel("Username").fill("nobody");
    await page.getByLabel("Password", { exact: true }).fill("wrong-" + i);
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page.getByRole("alert")).toHaveText("Invalid username or password.");
  }
  await page.getByLabel("Username").fill("nobody");
  await page.getByLabel("Password", { exact: true }).fill("still wrong");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("alert")).toContainText("Too many failed attempts");
});

test("after login, the visitor returns to the page they asked for", async ({ page }) => {
  await page.goto(url("accounts", "/reports?x=1"));
  await expect(page).toHaveURL(/\/auth\/login\?next=%2Freports%3Fx%3D1$/);
  await page.getByLabel("Username").fill(root.user);
  await page.getByLabel("Password", { exact: true }).fill(root.pw);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/reports\?x=1$/);
});
