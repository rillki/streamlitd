// App shell: top navigation with sections, st.topbar, st.banner, st.footer, userMenu.
const { test } = require("@playwright/test");
const { open, rerun, expect, url, waitIdle } = require("./helpers");

test("top navigation: links, section dropdown, keyboard, current page", async ({ page }) => {
  await open(page, "multipage");
  const nav = page.getByTestId("st-top-nav");
  await expect(nav).toBeVisible();
  await expect(page.getByTestId("st-sidebar")).not.toBeInViewport();         // no sidebar navigation
  await expect(nav.getByTestId("st-nav-link").filter({ hasText: "Home" })).toHaveAttribute("aria-current", "page");
  // a section is a dropdown menu
  const section = nav.getByTestId("st-nav-section");
  await expect(section).toHaveText(/Reports/);
  await section.click();
  await expect(page.getByRole("menuitem", { name: "Sales" })).toBeFocused();
  await rerun(page, () => page.getByRole("menuitem", { name: "Inventory" }).click());
  await expect(page.locator("h1")).toContainText("Inventory");
  await expect(page).toHaveURL(/\/inventory$/);
  await expect(section).toHaveClass(/active/);
  // keyboard: ↓ opens, arrows move, Enter picks, Esc closes and returns focus
  await section.focus();
  await page.keyboard.press("ArrowDown");
  await expect(page.getByRole("menuitem", { name: "Inventory" })).toBeFocused(); // the current page
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
  await expect(section).toBeFocused();
  await section.press("ArrowDown");
  await page.keyboard.press("ArrowUp");
  await rerun(page, () => page.keyboard.press("Enter"));
  await expect(page.locator("h1")).toContainText("Sales");
  await rerun(page, () => nav.getByTestId("st-nav-link").filter({ hasText: "Settings" }).click());
  await expect(page.locator("h1")).toContainText("Settings");
});

test("top navigation on a phone: one menu under the page title", async ({ browser }) => {
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await ctx.newPage();
  await page.goto(url("multipage", "/sales"));
  await waitIdle(page, 1);
  await expect(page.getByTestId("st-top-nav")).toBeHidden();
  const toggle = page.getByTestId("st-top-nav-toggle");
  await expect(toggle).toHaveText(/Sales/);
  await toggle.click();
  const menu = page.getByRole("menu");
  await expect(menu.getByText("Reports", { exact: true })).toBeVisible();  // section heading
  await expect(menu.getByRole("menuitem")).toHaveCount(5);
  await rerun(page, () => menu.getByRole("menuitem", { name: "Chat" }).click());
  await expect(page.locator("h1")).toContainText("Echo bot");
  await expect(toggle).toHaveText(/Chat/);
  const width = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(width).toBeLessThanOrEqual(390);
  await ctx.close();
});

test("header bar items, banner dismissal and footer", async ({ page }) => {
  await open(page, "multipage");
  const topbar = page.getByTestId("st-topbar");
  await topbar.getByRole("button", { name: "Help" }).click();
  await expect(page.getByTestId("st-toasts")).toContainText("Pages are in the bar at the top");
  await expect(page.getByTestId("st-footer")).toContainText("version 1.0");
  const banner = page.getByTestId("st-banner");
  await expect(banner).toContainText("Demo data");
  await rerun(page, () => page.getByTestId("st-nav-link").filter({ hasText: "Chat" }).click());
  await expect(banner).toBeVisible();                                         // on every page
  await banner.getByRole("button", { name: "Dismiss" }).click();
  await expect(banner).toHaveCount(0);
  await expect(page.getByTestId("st-banners")).toBeHidden();
  await page.reload();
  await waitIdle(page, 1);
  await expect(page.getByTestId("st-banner")).toHaveCount(0);               // stays closed in this tab
  // pages without these elements: no header bar background, no footer
  await open(page, "hello");
  await expect(page.getByTestId("st-footer")).toBeHidden();
  await expect(page.getByTestId("st-topbar")).toBeHidden();
  expect(await page.evaluate(() => document.getElementById("stApp").classList.contains("has-header"))).toBe(false);
});

test("user menu: picture or initials, app items, log out", async ({ page }) => {
  await page.goto(url("auth", "/"));
  await page.getByLabel("Username").fill("alice");
  await page.getByLabel("Password").fill("secret123");
  await page.getByRole("button", { name: "Sign in" }).click();
  await waitIdle(page, 1);
  const btn = page.getByTestId("st-user-menu");
  await expect(btn).toContainText("Alice");
  await expect(btn.locator(".st-avatar")).toHaveText("A");
  await btn.click();
  const menu = page.getByRole("menu");
  await expect(menu.getByText("alice@example.com")).toBeVisible();
  await expect(menu.getByRole("separator")).toHaveCount(2);
  await rerun(page, () => menu.getByRole("menuitem", { name: "Profile" }).click());
  await expect(page.getByText("You picked Profile in the user menu.")).toBeVisible();
  await btn.click();
  await page.getByRole("menuitem", { name: "Log out" }).click();
  await expect(page).toHaveURL(/\/auth\/login$/);
});

test("breadcrumbs, menu button and pagination", async ({ page }) => {
  await open(page, "multipage", "/sales");
  const bc = page.getByTestId("st-breadcrumbs");
  await expect(bc.locator("li")).toHaveText(["Home", "Reports", "Sales"]);
  await expect(bc.locator('[aria-current="page"]')).toHaveText("Sales");
  // pagination: 47 rows, 10 per page
  const pager = page.getByRole("navigation", { name: "Pages" });
  await expect(pager.getByRole("button", { name: "Previous page" })).toBeDisabled();
  await expect(pager.getByRole("button", { name: "Page 5" })).toBeVisible();
  await rerun(page, () => pager.getByRole("button", { name: "Next page" }).click());
  await expect(page.getByText("Sales item 11")).toBeVisible();
  await expect(pager.getByRole("button", { name: "Page 2" })).toHaveAttribute("aria-current", "page");
  // the buttons are redrawn, but keyboard focus stays on the one pressed
  await expect(pager.getByRole("button", { name: "Next page" })).toBeFocused();
  await rerun(page, () => page.keyboard.press("Enter"));
  await expect(pager.getByRole("button", { name: "Page 3" })).toHaveAttribute("aria-current", "page");
  await expect(pager.getByRole("button", { name: "Next page" })).toBeFocused();
  await rerun(page, () => pager.getByRole("button", { name: "Page 5" }).click());
  await expect(page.getByText("Sales item 47")).toBeVisible();
  await expect(pager.getByRole("button", { name: "Next page" })).toBeDisabled();
  await expect(pager.getByRole("button", { name: "Page 5" })).toBeFocused();
  // menu button: keyboard, separator, toast with the pick
  const exp = page.getByRole("button", { name: /Export/ });
  await exp.focus();
  await page.keyboard.press("ArrowDown");
  await expect(page.getByRole("menuitem", { name: "CSV" })).toBeFocused();
  await expect(page.getByRole("menu").getByRole("separator")).toHaveCount(1);
  await page.keyboard.press("End");
  await rerun(page, () => page.keyboard.press("Enter"));
  await expect(page.getByTestId("st-toasts")).toContainText("Exported Sales as Print");
  // a breadcrumb link goes to that page
  await rerun(page, () => bc.getByRole("link", { name: "Home" }).click());
  await expect(page.locator("h1")).toContainText("Home");
});
