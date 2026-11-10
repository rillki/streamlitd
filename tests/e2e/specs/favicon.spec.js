const { test } = require("@playwright/test");
const { open, rerun, expect, url } = require("./helpers");

const iconHrefs = (page) => page.locator("link[rel=icon]").evaluateAll((ls) => ls.map((l) => l.href));

test("default streamlitd favicon is served", async ({ page, request }) => {
  await open(page, "hello");
  // hello sets an emoji icon; the default links are in the served HTML
  const html = await (await request.get(url("widgets", "/"))).text();
  expect(html).toContain('href="_stcore/favicon.svg"');
  expect(html).toContain('href="_stcore/apple-touch-icon.png"');
  const svg = await request.get(url("widgets", "/_stcore/favicon.svg"));
  expect(svg.status()).toBe(200);
  expect(svg.headers()["content-type"]).toContain("image/svg+xml");
  expect(await svg.text()).toContain("<svg");
  const png = await request.get(url("widgets", "/_stcore/favicon-32.png"));
  expect(png.headers()["content-type"]).toContain("image/png");
  const touch = await request.get(url("widgets", "/_stcore/apple-touch-icon.png"));
  expect(touch.status()).toBe(200);
  const ico = await request.get(url("widgets", "/favicon.ico"));
  expect(ico.status()).toBe(200);
  expect(ico.headers()["content-type"]).toContain("image/x-icon");
});

test("an app without an icon keeps the default favicon", async ({ page }) => {
  await open(page, "widgets"); // sets a 🎛️ icon
  await open(page, "data");    // sets 📊
  await page.goto(url("prod", "/"));
  await page.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1);
  await expect(page.locator("html")).toHaveAttribute("data-favicon", "default");
});

test("app-wide favicon from config.toml ([server] favicon)", async ({ page, request }) => {
  const ico = await request.get(url("prod", "/favicon.ico"));
  expect(ico.status()).toBe(200);
  expect(ico.headers()["content-type"]).toContain("image/svg+xml");
  expect(await ico.text()).toContain("#00c27c");
  // also at the server root, although the app lives under /app
  const root = await request.get(url("prod", "/").replace("/app/", "/favicon.ico"));
  expect(await root.text()).toContain("#00c27c");
  await page.goto(url("prod", "/"));
  await page.waitForFunction(() => +(document.body.dataset.runs || 0) >= 1);
  const hrefs = await iconHrefs(page);
  expect(hrefs.length).toBe(1);
  expect(hrefs[0]).toMatch(/\/app\/_stcore\/favicon$/);
});

test("setPageConfig(icon:) emoji and multipage page icons", async ({ page }) => {
  await open(page, "hello"); // icon: "👋"
  await expect(page.locator("html")).toHaveAttribute("data-favicon", "custom");
  expect((await iconHrefs(page))[0]).toContain("data:image/svg+xml");
  expect(decodeURIComponent((await iconHrefs(page))[0])).toContain("👋");
  // multipage without an app icon: the tab shows the current page's icon
  await open(page, "multipage", "/chat");
  expect(decodeURIComponent((await iconHrefs(page))[0])).toContain("💬");
  await rerun(page, () => page.getByTestId("st-nav-link").filter({ hasText: "Settings" }).click());
  expect(decodeURIComponent((await iconHrefs(page))[0])).toContain("⚙️");
  // an app-level icon wins over page icons (hello sets 👋)
  await open(page, "hello");
  expect(decodeURIComponent((await iconHrefs(page))[0])).toContain("👋");
});
