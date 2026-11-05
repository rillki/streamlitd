const { test } = require("@playwright/test");
const { open, rerun, url, expect } = require("./helpers");

test("served under base URL path with config + secrets", async ({ page }) => {
  await open(page, "prod");
  expect(new URL(page.url()).pathname).toBe("/app/");
  await expect(page.getByText("Secret greeting: hello from secrets.toml")).toBeVisible();
  await expect(page.getByText("DB user: report_reader")).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("data-style", "finance");
  const img = page.getByTestId("st-image").locator("img");
  await expect(img).toHaveAttribute("src", /^_media\//);
  expect(await img.evaluate((i) => i.complete && i.naturalWidth > 0)).toBe(true);
  // the secret password is never sent to the browser
  const html = await page.content();
  expect(html).not.toContain("not-a-real-password");
});

test("CPU-busy session does not block other sessions", async ({ browser }) => {
  const a = await browser.newPage();
  const b = await browser.newPage();
  await open(a, "prod");
  await open(b, "prod");
  await a.getByRole("button", { name: "Busy CPU 3s" }).click();
  await a.waitForFunction(() => document.body.dataset.running === "1");
  const t0 = Date.now();
  await rerun(b, () => b.getByRole("button", { name: "Ping" }).click());
  await expect(b.getByText("pings=1")).toBeVisible();
  expect(Date.now() - t0).toBeLessThan(1500);
  expect(await a.evaluate(() => document.body.dataset.running)).toBe("1"); // A still busy
  await expect(a.getByText(/busy done/)).toBeVisible({ timeout: 10000 });
});

test("foreign Origin is rejected for WebSocket and uploads", async ({ request }) => {
  const ws = await request.get(url("prod", "/_stcore/ws"), {
    headers: { Origin: "http://evil.example", Connection: "Upgrade", Upgrade: "websocket",
      "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==" },
  });
  expect(ws.status()).toBe(403);
  const up = await request.post(url("prod", "/_upload/x/y?name=a.txt"), { headers: { Origin: "http://evil.example" }, data: "hi" });
  expect(up.status()).toBe(403);
  const ok = await request.get(url("prod", "/_stcore/health"));
  expect(await ok.text()).toBe("ok");
});
