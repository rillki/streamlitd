const { test } = require("@playwright/test");
const { open, rerun, expect } = require("./helpers");

test("renders title, markdown and sidebar", async ({ page }) => {
  await open(page, "hello");
  await expect(page).toHaveTitle("Hello streamlitd");
  await expect(page.locator("h1")).toContainText("Hello, streamlitd");
  await expect(page.locator(".st-color-blue")).toHaveText("colored");
  await expect(page.getByTestId("st-sidebar")).toContainText("You feel 😀 happy");
});

test("markdown neutralises javascript: links", async ({ page }) => {
  await open(page, "hello");
  const link = page.getByRole("link", { name: "click" });
  await expect(link).toHaveAttribute("href", "#");
});

test("text input + button rerun", async ({ page }) => {
  await open(page, "hello");
  const input = page.getByLabel("Your name");
  await expect(input).toHaveValue("World");
  await rerun(page, async () => { await input.fill("Kirill"); await input.press("Enter"); });
  await rerun(page, () => page.getByRole("button", { name: "Greet" }).click());
  await expect(page.getByTestId("st-alert-success")).toHaveText("Hello Kirill! 3x");
  // button value is true only for one run
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByTestId("st-alert-success")).toHaveCount(0);
  await expect(input).toHaveValue("Kirill");
});

test("session state survives reruns and is per session", async ({ browser }) => {
  const a = await browser.newPage();
  const b = await browser.newPage();
  await open(a, "hello");
  await open(b, "hello");
  for (let i = 0; i < 3; i++) await rerun(a, () => a.getByRole("button", { name: "Count clicks" }).click());
  await expect(a.locator("text=Clicks so far:")).toContainText("3");
  await expect(b.locator("text=Clicks so far:")).toContainText("0");
});

test("sidebar selectbox", async ({ page }) => {
  await open(page, "hello");
  await rerun(page, () => page.getByLabel("Mood").selectOption({ label: "😢 sad" }));
  await expect(page.getByTestId("st-sidebar")).toContainText("You feel 😢 sad");
  await page.getByRole("button", { name: "Close sidebar" }).click();
  await expect(page.locator("#stApp")).toHaveClass(/sidebar-collapsed/);
});
