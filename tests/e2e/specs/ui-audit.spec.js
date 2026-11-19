// UI audit across design styles × color schemes × modes × open states × viewports.
// Fails on any finding; writes test-results/ui-audit.{json,md} and screenshots of failing states.
const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");
const { url, waitIdle } = require("./helpers");
const { audit } = require("./audit");

const designs = ["streamlit", "terminal", "retro", "win95", "xp", "brutalist", "material", "glass"];
const outDir = path.join(__dirname, "..", "test-results");

async function openWith(browser, app, look, viewport, path) {
  const ctx = await browser.newContext({ viewport: viewport || { width: 1280, height: 800 } });
  await ctx.addInitScript((a) => localStorage.setItem("streamlitd-appearance", JSON.stringify(a)),
    Object.assign({ basis: "streamlit/streamlit/auto" }, look));
  const page = await ctx.newPage();
  await page.goto(url(app, path || "/"));
  await waitIdle(page, 1);
  await page.waitForTimeout(250);
  return page;
}

/** Open each kind of state on the design gallery, audit it, close it again. */
async function galleryStates(page, tag) {
  const all = [];
  const run = async (name, open, close) => {
    try {
      await open();
    } catch (e) {
      all.push({ state: tag + " / " + name, type: "interaction", where: name, detail: String(e.message).split("\n")[0] });
      await page.keyboard.press("Escape").catch(() => {});
      return;
    }
    await page.waitForTimeout(150);
    const f = await audit(page, tag + " / " + name);
    if (f.length) await page.screenshot({ path: path.join(outDir, "ui-audit", (tag + "-" + name).replace(/[^\w-]+/g, "_") + ".png") });
    all.push(...f);
    if (close) await close().catch(() => {});
    await page.waitForTimeout(80);
  };
  const esc = () => page.keyboard.press("Escape");
  const main = page.locator("#stRoot-0");
  await run("page", async () => {});
  await run("settings", () => page.getByTestId("st-settings").click(), async () => {});
  await run("settings design list", () => page.getByTestId("st-design-select").click(), esc);
  await run("settings scheme list", () => page.getByTestId("st-scheme-select").click(), esc);
  await page.getByTestId("st-settings").click(); // close the panel
  await run("selectbox", () => main.getByRole("combobox", { name: "Selectbox" }).click(), esc);
  await run("multiselect", () => main.getByRole("combobox", { name: "Multiselect" }).click(), esc);
  await run("date", () => main.getByRole("button", { name: "Open calendar" }).click(), esc);
  await run("time", () => main.getByRole("button", { name: "Choose time" }).click(), esc);
  await run("color", () => main.getByLabel("Color", { exact: true }).click(), esc);
  await run("sidebar select", () => page.getByTestId("st-sidebar").getByRole("combobox", { name: "Design style" }).click(), esc);
  await run("dialog", async () => {
    await page.getByRole("button", { name: "Open dialog" }).click();
    await page.getByRole("dialog", { name: "A dialog" }).waitFor();
  }, esc);
  return all;
}

function report(name, findings) {
  fs.mkdirSync(path.join(outDir, "ui-audit"), { recursive: true });
  fs.writeFileSync(path.join(outDir, "ui-audit-" + name + ".json"), JSON.stringify(findings, null, 1));
  const md = ["# UI audit: " + name, "", findings.length ? "| state | type | where | detail |\n|---|---|---|---|" : "No findings."]
    .concat(findings.map((f) => `| ${f.state} | ${f.type} | ${f.where.replace(/\|/g, "\\|")} | ${f.detail.replace(/\|/g, "\\|")} |`));
  fs.writeFileSync(path.join(outDir, "ui-audit-" + name + ".md"), md.join("\n") + "\n");
}
const summary = (f) => f.slice(0, 25).map((x) => `${x.state} | ${x.type} | ${x.where} | ${x.detail}`).join("\n");

test.describe.configure({ mode: "parallel" });

for (const mode of ["light", "dark"]) {
  test(`design gallery: every design, ${mode}`, async ({ browser }) => {
    test.setTimeout(240000);
    fs.mkdirSync(path.join(outDir, "ui-audit"), { recursive: true });
    const findings = [];
    for (const design of designs) {
      const page = await openWith(browser, "themes", { scheme: "streamlit", design, mode });
      findings.push(...(await galleryStates(page, `${design}/${mode}`)));
      await page.context().close();
    }
    report("gallery-" + mode, findings);
    expect(findings, summary(findings)).toEqual([]);
  });
}

test("cross color schemes", async ({ browser }) => {
  test.setTimeout(240000);
  const findings = [];
  for (const scheme of ["solarized", "paper", "finance"]) for (const design of designs) for (const mode of ["light", "dark"]) {
    const page = await openWith(browser, "themes", { scheme, design, mode });
    findings.push(...(await audit(page, `${design}/${scheme}/${mode} / page`)));
    await page.getByTestId("st-settings").click();
    findings.push(...(await audit(page, `${design}/${scheme}/${mode} / settings`)));
    await page.context().close();
  }
  report("schemes", findings);
  expect(findings, summary(findings)).toEqual([]);
});

test("phone viewport", async ({ browser }) => {
  test.setTimeout(240000);
  const findings = [];
  for (const design of designs) {
    const page = await openWith(browser, "themes", { scheme: "streamlit", design, mode: "light" }, { width: 390, height: 844 });
    findings.push(...(await audit(page, `${design}/phone / page`)));
    await page.getByTestId("st-settings").click();
    findings.push(...(await audit(page, `${design}/phone / settings`)));
    await page.getByTestId("st-design-select").click();
    findings.push(...(await audit(page, `${design}/phone / settings design list`)));
    await page.keyboard.press("Escape");
    await page.getByTestId("st-settings").click();
    await page.locator("#stRoot-0").getByRole("button", { name: "Open calendar" }).click();
    findings.push(...(await audit(page, `${design}/phone / date`)));
    await page.context().close();
  }
  report("phone", findings);
  expect(findings, summary(findings)).toEqual([]);
});

test("other example apps", async ({ browser }) => {
  test.setTimeout(240000);
  const findings = [];
  for (const design of ["streamlit", "terminal", "win95", "brutalist"]) for (const mode of ["light", "dark"]) {
    for (const app of ["widgets", "data", "fragments", "hello", "custom", "multipage"]) {
      // examples/custom starts with its own scheme "acme", and adds the "neon" design
      const look = app === "custom" ? { scheme: "acme", basis: "acme/streamlit/auto" } : { scheme: "streamlit" };
      const page = await openWith(browser, app, Object.assign(look, { design, mode }));
      findings.push(...(await audit(page, `${app}:${design}/${mode} / page`)));
      if (app === "multipage") {
        // the header bar with a section menu open
        await page.getByTestId("st-nav-section").click();
        findings.push(...(await audit(page, `${app}:${design}/${mode} / section menu`)));
        // a report page: breadcrumbs, menu button (open), pagination
        await page.getByRole("menuitem", { name: "Sales" }).click();
        await page.waitForFunction(() => document.body.dataset.running === "0" && document.querySelector('[data-testid="st-breadcrumbs"]'));
        await page.getByRole("button", { name: /Export/ }).click();
        findings.push(...(await audit(page, `${app}:${design}/${mode} / report page, export menu`)));
        await page.keyboard.press("Escape");
      }
      if (app === "widgets") for (const tab of ["Layout", "Forms", "Status", "More"]) {
        await page.getByRole("tab", { name: tab }).click();
        findings.push(...(await audit(page, `${app}:${design}/${mode} / tab ${tab}`)));
        if (tab === "More") {
          await page.getByRole("button", { name: /^Regions:/ }).click();
          findings.push(...(await audit(page, `${app}:${design}/${mode} / tree select open`)));
          await page.keyboard.press("Escape");
          await page.locator('[data-testid="st-date_range_input"]').getByRole("button", { name: "Open calendar" }).click();
          findings.push(...(await audit(page, `${app}:${design}/${mode} / date range calendar`)));
          await page.keyboard.press("Escape");
        }
      }
      await page.context().close();
    }
  }
  // the app shell and the extra elements in the other four designs too
  for (const design of ["retro", "xp", "material", "glass"]) for (const mode of ["light", "dark"]) {
    let page = await openWith(browser, "multipage", { scheme: "streamlit", design, mode }, null, "/sales");
    await page.getByRole("button", { name: /Export/ }).click();
    findings.push(...(await audit(page, `multipage:${design}/${mode} / report page, export menu`)));
    await page.context().close();
    page = await openWith(browser, "widgets", { scheme: "streamlit", design, mode });
    await page.getByRole("tab", { name: "More" }).click();
    findings.push(...(await audit(page, `widgets:${design}/${mode} / tab More`)));
    await page.getByRole("button", { name: /^Regions:/ }).click();
    findings.push(...(await audit(page, `widgets:${design}/${mode} / tree select open`)));
    await page.context().close();
  }
  // examples/business: KPI trends, proportion bar, link cards, tree table with grouped headers, feed, folding sidebar
  for (const design of ["streamlit", "terminal", "win95", "brutalist", "glass"]) for (const mode of ["light", "dark"]) {
    for (const p of ["/", "/suppliers", "/inbox", "/order-plan?focus=d3"]) {
      const page = await openWith(browser, "business", { scheme: "streamlit", design, mode }, null, p);
      findings.push(...(await audit(page, `business${p}:${design}/${mode}`)));
      await page.context().close();
    }
  }
  // the app-defined design and config scheme of examples/custom
  for (const mode of ["light", "dark"]) {
    const page = await openWith(browser, "custom", { scheme: "dusk", design: "neon", mode, basis: "acme/streamlit/auto" });
    findings.push(...(await audit(page, `custom:neon+dusk/${mode} / page`)));
    await page.context().close();
  }
  report("apps", findings);
  expect(findings, summary(findings)).toEqual([]);
});

test("login, sign-up and account pages, and the admin panel", async ({ browser }) => {
  test.setTimeout(180000);
  const findings = [];
  for (const mode of ["light", "dark"]) {
    // the server-rendered pages follow the OS color mode
    for (const [app, p, vp] of [["accounts", "/auth/login"], ["accounts", "/auth/register"], ["accounts", "/auth/register", { width: 390, height: 800 }],
      ["auth", "/auth/login"]]) {
      const ctx = await browser.newContext({ colorScheme: mode, viewport: vp || { width: 1280, height: 800 } });
      const page = await ctx.newPage();
      await page.goto(url(app, p));
      findings.push(...(await audit(page, `${app}${p}${vp ? " (phone)" : ""} / ${mode}`)));
      await ctx.close();
    }
    // alice (a config user and admin): the read-only account page, then the admin panel in some designs
    const ctx = await browser.newContext({ colorScheme: mode });
    const page = await ctx.newPage();
    await page.goto(url("auth", "/auth/login"));
    await page.getByLabel("Username").fill("alice");
    await page.getByLabel("Password").fill("streamlitd-demo");
    await page.getByRole("button", { name: "Sign in" }).click();
    await waitIdle(page, 1);
    await page.goto(url("auth", "/auth/account"));
    findings.push(...(await audit(page, `auth/account / ${mode}`)));
    for (const design of ["streamlit", "terminal", "win95", "glass"]) {
      await page.evaluate((a) => localStorage.setItem("streamlitd-appearance", JSON.stringify(a)),
        { basis: "streamlit/streamlit/auto", scheme: "streamlit", design, mode });
      await page.goto(url("auth", "/"));
      await waitIdle(page, 1);
      for (const tab of ["Users", "Add user", "Invites"]) {
        await page.getByRole("tab", { name: tab }).click();
        findings.push(...(await audit(page, `auth admin panel:${design}/${mode} / ${tab}`)));
      }
    }
    await ctx.close();
  }
  report("auth-pages", findings);
  expect(findings, summary(findings)).toEqual([]);
});

test("header controls: the ⋮ menu and the appearance panel opened from the sidebar", async ({ browser }) => {
  test.setTimeout(120000);
  const findings = [];
  for (const design of ["streamlit", "terminal", "win95", "glass"]) for (const mode of ["light", "dark"]) {
    let page = await openWith(browser, "hello-menu", { scheme: "streamlit", design, mode });
    await page.getByTestId("st-app-menu").click();
    findings.push(...(await audit(page, `hello-menu:${design}/${mode} / ⋮ menu`)));
    await page.getByRole("menuitem", { name: /Appearance/ }).click();
    findings.push(...(await audit(page, `hello-menu:${design}/${mode} / panel from ⋮`)));
    await page.context().close();
    for (const vp of [null, { width: 390, height: 800 }]) {
      page = await openWith(browser, "hello", { scheme: "streamlit", design, mode }, vp);
      if (vp) await page.getByRole("button", { name: "Open sidebar" }).click();
      await page.getByTestId("st-settings-button").click();
      findings.push(...(await audit(page, `hello:${design}/${mode}${vp ? " (phone)" : ""} / panel from the sidebar`)));
      await page.context().close();
    }
  }
  report("header-controls", findings);
  expect(findings, summary(findings)).toEqual([]);
});

// The larger examples (examples/helpdesk, ...): every page, plus open states (a selected row, dialogs).
// `user` signs in first; `states` run on one page and are audited after each step.
const bigApps = [
  { app: "helpdesk", user: "alice", pages: ["/", "/tickets", "/customers", "/users"], states: [
    ["/tickets", "ticket selected", async (page) => { await page.getByTestId("st-dataframe").locator("tbody tr").first().click(); await waitIdle(page, 2); }],
    ["/tickets", "edit dialog", async (page) => { await page.getByRole("button", { name: "Edit…" }).click(); await page.getByRole("dialog").waitFor(); }],
    ["/tickets", "nested confirm", async (page) => { await page.getByRole("button", { name: "Close ticket…" }).click(); await expect(page.getByRole("dialog")).toHaveCount(2); }],
  ] },
  { app: "planning", pages: ["/", "/plan-vs-fact", "/deliveries", "/import"], states: [
    ["/", "review dialog", async (page) => {
      const c = page.getByTestId("st-data-editor").getByLabel("Dec row 1"); await c.fill("1234"); await c.press("Enter"); await waitIdle(page, 2);
      await page.getByRole("button", { name: "Review & save" }).click(); await page.getByRole("dialog").waitFor(); }],
    ["/deliveries", "delivery dialog", async (page) => { await page.locator("[data-item]").first().click(); await page.getByRole("dialog").waitFor(); }],
    ["/import", "match step", async (page) => { await page.getByRole("button", { name: "Use the sample file" }).click(); await page.getByText("Every supplier name is known.").or(page.getByText("Some names in the file differ")).waitFor(); }],
    ["/import", "review step", async (page) => { await page.getByRole("button", { name: "Next" }).click(); await page.getByTestId("st-dataframe").waitFor(); }],
  ] },
  { app: "todo", signUp: true, pages: ["/", "/list-work", "/upcoming", "/lists"], states: [
    ["/list-work", "edit dialog", async (page) => { await page.getByRole("button", { name: "Edit" }).first().click(); await page.getByRole("dialog").waitFor(); }],
    ["/list-work", "nested delete", async (page) => { await page.getByRole("button", { name: "Delete…" }).click(); await expect(page.getByRole("dialog")).toHaveCount(2); }],
    ["/list-home", "bulk table", async (page) => { await page.getByText("Select several").click(); await page.getByTestId("st-dataframe").waitFor(); await page.getByLabel("Select row 0").check(); await waitIdle(page, 2); }],
  ] },
  { app: "gantt", pages: ["/", "/tasks"], states: [
    ["/", "day scale", async (page) => { await page.getByRole("radiogroup", { name: "Scale" }).getByRole("button", { name: "day" }).click(); await waitIdle(page, 2); }],
    ["/", "edit dialog", async (page) => { await page.locator('[data-item="t5"]').first().click(); await page.getByRole("dialog").waitFor(); }],
    ["/", "nested delete", async (page) => { await page.getByRole("button", { name: "Delete…" }).click(); await expect(page.getByRole("dialog")).toHaveCount(2); }],
  ] },
  { app: "monitor", pages: ["/", "/services", "/alerts"], states: [
    ["/services", "service selected", async (page) => { await page.getByTestId("st-dataframe").locator("tbody tr").nth(2).click(); await page.getByTestId("st-vega-lite").first().waitFor(); }],
    ["/alerts", "rules tab", async (page) => { await page.getByRole("tab", { name: "Rules" }).click(); await page.getByTestId("st-data-editor").waitFor(); }],
  ] },
];

async function signIn(page, app, user) {
  await page.goto(url(app, "/"));
  await page.getByLabel("Username").fill(user);
  await page.getByLabel("Password").fill("streamlitd-demo");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).not.toHaveURL(/\/auth\/login/);
  await waitIdle(page, 1);
}

test("larger examples: pages and open states", async ({ browser }) => {
  test.setTimeout(300000);
  const findings = [];
  for (const b of bigApps) for (const design of ["streamlit", "terminal", "win95", "glass"]) for (const mode of ["light", "dark"]) {
    const tag = `${b.app}:${design}/${mode}`;
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    await ctx.addInitScript((a) => localStorage.setItem("streamlitd-appearance", JSON.stringify(a)),
      { basis: "streamlit/streamlit/auto", scheme: "streamlit", design, mode });
    const page = await ctx.newPage();
    if (b.user) await signIn(page, b.app, b.user);
    if (b.signUp) {
      await page.goto(url(b.app, "/auth/register"));
      await page.getByLabel("Username").fill("audit" + Date.now().toString(36) + Math.floor(Math.random() * 1e4));
      await page.getByLabel("Password", { exact: true }).fill("streamlitd-demo");
      await page.getByLabel("Repeat the password").fill("streamlitd-demo");
      await page.getByRole("button", { name: "Create account" }).click();
      await expect(page).not.toHaveURL(/\/auth\//);
      await waitIdle(page, 1);
    }
    for (const p of b.pages) {
      await page.goto(url(b.app, p));
      await waitIdle(page, 1);
      await page.waitForTimeout(250);
      findings.push(...(await audit(page, `${tag} ${p}`)));
    }
    let at = null;
    for (const [p, name, act] of b.states || []) {
      if (p !== at) { await page.goto(url(b.app, p)); await waitIdle(page, 1); at = p; }
      await act(page);
      await page.waitForTimeout(200);
      findings.push(...(await audit(page, `${tag} ${p} / ${name}`)));
    }
    await ctx.close();
  }
  report("examples", findings);
  expect(findings, summary(findings)).toEqual([]);
});

test("no native browser pop-up controls anywhere", async ({ browser }) => {
  for (const app of ["hello", "widgets", "data", "themes", "fragments", "multipage", "extras", "tutorial", "custom", "business", "planning", "gantt", "monitor"]) {
    const page = await openWith(browser, app, { scheme: "streamlit", design: "streamlit", mode: "light" });
    const native = await page.evaluate(() => document.querySelectorAll("select, datalist, input[type=date], input[type=time], input[type=color], input[type=datetime-local], input[type=month], input[type=week]").length);
    expect(native, app).toBe(0);
    await page.context().close();
  }
});
