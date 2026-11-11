// App extensions (examples/custom): color schemes, a design style and native widgets/elements
// registered in D code and in config.toml.
const { test } = require("@playwright/test");
const { open, rerun, expect, pick, url, waitIdle } = require("./helpers");

const cssVar = (page, name) => page.evaluate((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), name);
const html = (page) => page.locator("html");
const rating = (page, label) => page.locator(`[data-testid="st-custom-rating"][data-label="${label}"]`);

test("app color schemes and design: registered in D and in config.toml", async ({ page }) => {
  await open(page, "custom");
  // [theme] scheme = "acme" (registered in app.d) is the default; tokens not given come from "streamlit"
  await expect(html(page)).toHaveAttribute("data-scheme", "acme");
  expect(await cssVar(page, "--primary")).toBe("#0055aa");
  expect(await cssVar(page, "--bg")).toBe("#ffffff");
  expect(await cssVar(page, "--chart-2")).toBe("#ff8800");
  await page.getByTestId("st-settings").click();
  // the config scheme in the menu, with light and dark variants
  await pick(page, page.getByTestId("st-scheme-select"), "Dusk");
  await expect(html(page)).toHaveAttribute("data-scheme", "dusk");
  expect(await cssVar(page, "--primary")).toBe("#7c3aed");
  expect(await cssVar(page, "--bg")).toBe("#faf7ff");
  await page.getByRole("button", { name: "Dark", exact: true }).click();
  expect(await cssVar(page, "--bg")).toBe("#15111f");
  // the config design: menu entry, preview card, forced tokens and its CSS
  await expect(page.locator('[data-design-card="neon"]')).toBeVisible();
  await pick(page, page.getByTestId("st-design-select"), "Neon");
  await expect(html(page)).toHaveAttribute("data-design", "neon");
  expect(await cssVar(page, "--radius")).toBe("6px");
  const shadow = await page.getByRole("button", { name: "Submit" }).evaluate((e) => getComputedStyle(e).boxShadow);
  expect(shadow).not.toBe("none");
  // the scheme from D code works in dark mode too
  await pick(page, page.getByTestId("st-scheme-select"), "Acme Corp");
  expect(await cssVar(page, "--bg")).toBe("#0b1220");
  expect(await cssVar(page, "--primary")).toBe("#4d9fff");
});

test("custom widget: value round trip, in-place updates, form, display element", async ({ page }) => {
  await open(page, "custom");
  const w = rating(page, "How do you like it?");
  await expect(w.getByRole("radio")).toHaveCount(5);
  await expect(w.locator(".rating-star.on")).toHaveCount(3);          // default 3
  await expect(page.getByText("You picked 3 of 5 stars.")).toBeVisible();
  await expect(page.getByTestId("st-custom-badge").first()).toHaveText("custom element");
  // the help tooltip comes from api.label()
  await expect(w.locator(".widget-label .help")).toHaveAttribute("title", /rating\.js/);

  const node = await w.elementHandle();
  await rerun(page, () => w.getByRole("radio", { name: "5 of 5" }).click());
  await expect(page.getByText("You picked 5 of 5 stars.")).toBeVisible();
  await expect(w.locator(".rating-star.on")).toHaveCount(5);
  expect(await node.evaluate((n) => n.isConnected)).toBe(true);        // updated in place, not re-created
  await expect(page.getByTestId("st-custom-badge").filter({ hasText: "thank you!" })).toBeVisible();
  // the value is in session state: it survives a rerun
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByText("You picked 5 of 5 stars.")).toBeVisible();

  // inside a form: nothing is sent until submit
  const fw = rating(page, "Rate the form");
  await expect(fw.getByRole("radio")).toHaveCount(10);
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  await fw.getByRole("radio", { name: "7 of 10" }).click();
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs);
  await rerun(page, () => page.getByRole("button", { name: "Submit" }).click());
  await expect(page.getByTestId("st-alert-success")).toHaveText("Submitted 7/10");
});

test("a broken element script shows an error box and does not stop the other elements", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(url("custom", "/?demo=broken"));
  await waitIdle(page, 1);
  await expect(page.getByTestId("st-custom-missing")).toContainText('Custom element "ghost" has no renderer');
  expect(errors.join("\n")).toMatch(/SyntaxError/);
  // the other elements have their own scripts: still drawn and working
  const w = rating(page, "How do you like it?");
  await expect(w.getByRole("radio")).toHaveCount(5);
  await rerun(page, () => w.getByRole("radio", { name: "4 of 5" }).click());
  await expect(page.getByText("You picked 4 of 5 stars.")).toBeVisible();
});

test("extension files are cacheable and absent for apps without extensions", async ({ request }) => {
  const page = await (await request.get(url("custom"))).text();
  // one script per element
  for (const name of ["rating", "badge", "ghost"]) expect(page).toMatch(new RegExp(`_stcore/ext/${name}\\.js\\?v=[0-9a-f]{12}`));
  const m = page.match(/_stcore\/ext\/rating\.js\?v=([0-9a-f]{12})/);
  const js = await request.get(url("custom", "/_stcore/ext/rating.js?v=" + m[1]));
  expect(js.headers()["cache-control"]).toContain("immutable");
  const body = await js.text();
  expect(body).toContain('StreamlitD.registerElement("rating"');
  expect(body).not.toContain('"badge"');
  expect((await request.get(url("custom", "/_stcore/ext/nope.js"))).status()).toBe(404);
  expect(page).toMatch(/_stcore\/ext\.css\?v=[0-9a-f]{12}/);
  const hello = await (await request.get(url("hello"))).text();
  expect(hello).not.toContain("_stcore/ext.");
  expect((await request.get(url("hello", "/_stcore/ext.css"))).status()).toBe(404);
});
