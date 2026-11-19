const { test } = require("@playwright/test");
const { url, waitIdle, expect } = require("./helpers");

test("app requires login; password login and logout", async ({ page, request }) => {
  await page.goto(url("auth", "/"));
  await expect(page).toHaveURL(/\/auth\/login$/);
  await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
  // websocket is refused without a session cookie
  const ws = await request.get(url("auth", "/_stcore/ws"), { headers: { Connection: "Upgrade", Upgrade: "websocket",
    "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==" } });
  expect(ws.status()).toBe(401);

  await page.getByLabel("Username").fill("alice");
  await page.getByLabel("Password").fill("wrong");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByRole("alert")).toHaveText("Invalid username or password.");

  await page.getByLabel("Username").fill("alice");
  await page.getByLabel("Password").fill("streamlitd-demo");
  await page.getByRole("button", { name: "Sign in" }).click();
  await waitIdle(page, 1);
  await expect(page.getByText("Hello Alice (alice@example.com), signed in via password.")).toBeVisible();
  const cookies = await page.context().cookies();
  const c = cookies.find((x) => x.name === "streamlitd_auth");
  expect(c.httpOnly).toBe(true);

  await page.getByRole("button", { name: "Log out" }).click();
  await expect(page).toHaveURL(/\/auth\/login$/);
  await page.goto(url("auth", "/"));
  await expect(page).toHaveURL(/\/auth\/login$/);
});

test("OIDC login through a provider", async ({ page }) => {
  await page.goto(url("auth", "/"));
  await page.getByRole("link", { name: "Continue with Mock SSO" }).click();
  await waitIdle(page, 1);
  await expect(page.getByText("Hello Mock User (mock@example.com), signed in via mock.")).toBeVisible();
});

test("tampered auth cookie is rejected", async ({ page, context }) => {
  await context.addCookies([{ name: "streamlitd_auth", value: "eyJzdWIiOiJldmUifQ.AAAA", url: url("auth", "/") }]);
  await page.goto(url("auth", "/"));
  await expect(page).toHaveURL(/\/auth\/login$/);
});
