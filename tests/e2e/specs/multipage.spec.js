const { test } = require("@playwright/test");
const { open, rerun, expect, url } = require("./helpers");

test("navigation between pages updates URL", async ({ page }) => {
  await open(page, "multipage");
  await expect(page.locator("h1")).toContainText("Home");
  const links = page.getByTestId("st-nav-link");
  await expect(links).toHaveCount(3);
  await rerun(page, () => links.filter({ hasText: "Settings" }).click());
  await expect(page.locator("h1")).toContainText("Settings");
  await expect(page).toHaveURL(/\/settings/);
  await rerun(page, () => page.goBack());
  await expect(page.locator("h1")).toContainText("Home");
});

test("deep link, page_link and switch_page", async ({ page }) => {
  await open(page, "multipage", "/chat");
  await expect(page.locator("h1")).toContainText("Echo bot");
  await page.goto(url("multipage", "/"));
  await rerun(page, () => page.getByText("Go to the chat page").click());
  await expect(page.locator("h1")).toContainText("Echo bot");
  await page.goto(url("multipage", "/"));
  await page.waitForFunction(() => document.body.dataset.running === "0" && +document.body.dataset.runs >= 1);
  await page.getByRole("button", { name: "Switch to settings" }).click();
  await expect(page.locator("h1")).toContainText("Settings");
  await expect(page).toHaveURL(/\/settings/);
});

test("chat input and history", async ({ page }) => {
  await open(page, "multipage", "/chat");
  const input = page.getByTestId("st-chat-input").locator("textarea");
  await rerun(page, async () => { await input.fill("hello"); await input.press("Enter"); });
  await expect(page.getByTestId("st-chat-message")).toHaveCount(2);
  await expect(page.getByTestId("st-chat-message").nth(1)).toContainText("You said: HELLO");
  await rerun(page, async () => { await input.fill("again"); await page.getByRole("button", { name: "Send" }).click(); });
  await expect(page.getByTestId("st-chat-message")).toHaveCount(4);
  await rerun(page, () => page.getByRole("button", { name: "Clear chat" }).click());
  await expect(page.getByTestId("st-chat-message")).toHaveCount(0);
});

test("query params round trip", async ({ page }) => {
  await open(page, "multipage", "/settings?theme=dark");
  await expect(page.getByLabel("dark")).toBeChecked();
  await rerun(page, () => page.getByLabel("light").check());
  await expect(page).toHaveURL(/theme=light/);
  await expect(page.getByText("Query param theme = light")).toBeVisible();
});
