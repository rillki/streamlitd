// UI audit across design styles × color schemes × modes × open states × viewports.
// Fails on any finding; writes test-results/ui-audit.{json,md} and screenshots of failing states.
const { test, expect } = require("@playwright/test");
const fs = require("fs");
const path = require("path");
const { url, waitIdle } = require("./helpers");
const { audit } = require("./audit");

const designs = ["streamlit", "terminal", "retro", "win95", "xp", "brutalist", "material", "glass"];
const outDir = path.join(__dirname, "..", "test-results");

async function openWith(browser, app, look, viewport) {
  const ctx = await browser.newContext({ viewport: viewport || { width: 1280, height: 800 } });
  await ctx.addInitScript((a) => localStorage.setItem("streamlitd-appearance", JSON.stringify(a)),
    Object.assign({ basis: "streamlit/streamlit/auto" }, look));
  const page = await ctx.newPage();
  await page.goto(url(app));
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
    for (const app of ["widgets", "data", "fragments", "hello", "custom"]) {
      // examples/custom starts with its own scheme "acme", and adds the "neon" design
      const look = app === "custom" ? { scheme: "acme", basis: "acme/streamlit/auto" } : { scheme: "streamlit" };
      const page = await openWith(browser, app, Object.assign(look, { design, mode }));
      findings.push(...(await audit(page, `${app}:${design}/${mode} / page`)));
      if (app === "widgets") for (const tab of ["Layout", "Forms", "Status"]) {
        await page.getByRole("tab", { name: tab }).click();
        findings.push(...(await audit(page, `${app}:${design}/${mode} / tab ${tab}`)));
      }
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

test("no native browser pop-up controls anywhere", async ({ browser }) => {
  for (const app of ["hello", "widgets", "data", "themes", "fragments", "multipage", "extras", "tutorial", "custom"]) {
    const page = await openWith(browser, app, { scheme: "streamlit", design: "streamlit", mode: "light" });
    const native = await page.evaluate(() => document.querySelectorAll("select, datalist, input[type=date], input[type=time], input[type=color], input[type=datetime-local], input[type=month], input[type=week]").length);
    expect(native, app).toBe(0);
    await page.context().close();
  }
});
