const { test } = require("@playwright/test");
const { open, rerun, widget, expect } = require("./helpers");

const leftText = (page) => page.locator("pre.st-text").filter({ hasText: "name=" });
const rightText = (page) => page.locator("pre.st-text").filter({ hasText: "agree=" });

test("text, number and slider inputs", async ({ page }) => {
  await open(page, "widgets");
  await expect(leftText(page)).toContainText("name=Ann pwdlen=0 age=30 weight=70.5 level=25 range=20-80 size=M");
  await rerun(page, async () => { await page.getByLabel("Name").fill("Bob"); await page.getByLabel("Name").press("Enter"); });
  await rerun(page, async () => { await page.getByLabel("Password").fill("secret"); await page.getByLabel("Password").blur(); });
  await rerun(page, () => widget(page, "number_input", "Age").getByRole("button", { name: "Increment" }).click());
  await rerun(page, async () => { const w = page.getByLabel("Weight (kg)"); await w.fill("80"); await w.press("Enter"); });
  await rerun(page, async () => {
    const s = widget(page, "slider", "Level").locator("input[type=range]");
    await s.focus();
    await s.press("End");
  });
  await expect(leftText(page)).toContainText("name=Bob pwdlen=6 age=31 weight=80.0 level=100");
  await rerun(page, async () => {
    const s = widget(page, "select_slider", "T-shirt size").locator("input[type=range]");
    await s.focus();
    await s.press("ArrowRight");
  });
  await expect(leftText(page)).toContainText("size=L");
  await rerun(page, async () => { const t = page.getByLabel("Bio"); await t.fill("Multi\nline"); await t.blur(); });
  await expect(leftText(page)).toContainText("bio=Multi\nline");
});

test("choice widgets", async ({ page }) => {
  await open(page, "widgets");
  await rerun(page, () => page.getByLabel("I agree").check());
  await rerun(page, () => page.getByText("Dark mode").click());
  await rerun(page, () => page.getByLabel("Blue").check());
  await rerun(page, () => page.getByLabel("City").selectOption({ label: "Shymkent" }));
  await rerun(page, () => widget(page, "multiselect", "Languages").locator("select").selectOption({ label: "Rust" }));
  await rerun(page, () => page.getByRole("button", { name: "Remove D" }).click());
  await rerun(page, () => page.getByLabel("Day").fill("2025-01-31"));
  await rerun(page, () => page.getByLabel("Time").fill("14:15"));
  await expect(rightText(page)).toHaveText("agree=true dark=true color=Blue city=Shymkent langs=Rust day=2025-01-31 time=14:15 pick=#ff4b4b");
});

test("callbacks, keyed state and st.rerun", async ({ page }) => {
  await open(page, "widgets");
  const counter = page.getByTestId("st-metric").filter({ hasText: "Counter" });
  await rerun(page, () => page.getByRole("button", { name: "➕ Increment" }).click());
  await rerun(page, () => page.getByRole("button", { name: "➕ Increment" }).click());
  await expect(counter.locator(".metric-value")).toHaveText("2");
  await rerun(page, () => page.getByRole("button", { name: "Reset", exact: true }).click());
  await expect(counter.locator(".metric-value")).toHaveText("0");
  await rerun(page, () => page.getByRole("button", { name: "Fill note" }).click());
  await expect(page.getByLabel('Keyed input (st.session["note"])')).toHaveValue("filled from code");
  await expect(page.getByText("note is: filled from code")).toBeVisible();
});

test("tabs, expander, empty and popover", async ({ page }) => {
  await open(page, "widgets");
  await expect(page.getByText("A bordered container")).toBeHidden();
  await page.getByRole("tab", { name: "Layout" }).click();
  await expect(page.getByText("A bordered container")).toBeVisible();
  await expect(page.getByTestId("st-metric").filter({ visible: true })).toHaveCount(3);
  await expect(page.getByText("Hidden content inside")).toBeHidden();
  await page.getByText("Click to expand").click();
  await expect(page.getByText("Hidden content inside")).toBeVisible();
  // st.empty keeps only the last element
  await expect(page.getByText("This placeholder was replaced")).toHaveCount(0);
  await expect(page.getByText("by a newer element")).toBeVisible();
  await page.getByRole("button", { name: "Open popover" }).click();
  await expect(page.getByText("Popover content")).toBeVisible();
  // tab selection and expander state survive reruns
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByText("Hidden content inside")).toBeVisible();
});

test("form submits values only on submit and clears", async ({ page }) => {
  await open(page, "widgets");
  await page.getByRole("tab", { name: "Forms" }).click();
  const runs = await page.evaluate(() => +document.body.dataset.runs);
  await page.getByLabel("Email").fill("ann@example.com");
  await page.getByLabel("Email").blur();
  await page.getByLabel("Plan").selectOption({ label: "Pro" });
  await page.waitForTimeout(300);
  expect(await page.evaluate(() => +document.body.dataset.runs)).toBe(runs); // no rerun yet
  await rerun(page, () => page.getByRole("button", { name: "Sign up" }).click());
  await expect(page.getByText("Signed up ann@example.com for Pro with 5 seats")).toBeVisible();
  await expect(page.getByLabel("Email")).toHaveValue("");
  await expect(page.getByLabel("Plan")).toHaveValue("0");
});

test("pending form values survive unrelated reruns", async ({ page }) => {
  await open(page, "widgets");
  await page.getByRole("tab", { name: "Forms" }).click();
  await page.getByLabel("Email").fill("pending@example.com");
  await page.getByLabel("Email").blur();
  await rerun(page, () => page.keyboard.press("r"));
  await expect(page.getByLabel("Email")).toHaveValue("pending@example.com");
  await rerun(page, () => page.getByRole("button", { name: "Sign up" }).click());
  await expect(page.getByText("Signed up pending@example.com for Free with 5 seats")).toBeVisible();
});

test("status elements, toast, progress and exceptions", async ({ page }) => {
  await open(page, "widgets");
  await page.getByRole("tab", { name: "Status" }).click();
  for (const t of ["Success", "Info", "Warning", "Error"]) await expect(page.getByRole("alert").filter({ hasText: t + " message" })).toBeVisible();
  await rerun(page, () => page.getByRole("button", { name: "Toast me" }).click());
  await expect(page.getByTestId("st-toast")).toContainText("Hello from a toast!");
  await rerun(page, () => page.getByRole("button", { name: "Run long task" }).click());
  await expect(page.getByText("Long task done")).toBeVisible();
  await expect(page.getByTestId("st-progress")).toHaveAttribute("aria-valuenow", "100");
  await expect(page.getByTestId("st-spinner")).toHaveCount(0);
  await rerun(page, () => page.getByRole("button", { name: "Raise exception" }).click());
  await expect(page.getByTestId("st-exception")).toContainText("Something went wrong in the app");
});
