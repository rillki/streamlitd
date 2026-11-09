// Themed controls (assets/ui.js): combobox, multiselect, date, time and color pickers.
const { test } = require("@playwright/test");
const { open, rerun, expect, setColor } = require("./helpers");

const main = (page) => page.locator("#stRoot-0");
const listbox = (page) => page.locator("#stPopups [role=listbox]").last();

test("combobox: ARIA, keyboard, filtering, no results, revert", async ({ page }) => {
  await open(page, "widgets");
  const cb = page.getByRole("combobox", { name: "City" });
  await expect(cb).toHaveAttribute("aria-expanded", "false");
  await expect(cb).toHaveValue("Almaty");
  await cb.focus();
  await cb.press("ArrowDown");
  await expect(cb).toHaveAttribute("aria-expanded", "true");
  await expect(listbox(page).getByRole("option")).toHaveCount(3);
  await expect(listbox(page).getByRole("option", { name: "Almaty" })).toHaveAttribute("aria-selected", "true");
  // filter, then pick with the keyboard
  await cb.pressSequentially("shy");
  await expect(listbox(page).getByRole("option")).toHaveCount(1);
  await expect(cb).toHaveAttribute("aria-activedescendant", /-o0$/);
  await rerun(page, () => cb.press("Enter"));
  await expect(cb).toHaveValue("Shymkent");
  await expect(page.locator("pre.st-text").filter({ hasText: "agree=" })).toContainText("city=Shymkent");
  // no results + Escape reverts
  await cb.click();
  await cb.pressSequentially("zzz");
  await expect(page.locator("#stPopups .st-noresults")).toHaveText("No results");
  await cb.press("Escape");
  await expect(cb).toHaveAttribute("aria-expanded", "false");
  await expect(cb).toHaveValue("Shymkent");
  // Home/End navigation
  await cb.press("ArrowDown");
  await cb.press("End");
  await expect(cb).toHaveAttribute("aria-activedescendant", /-o2$/);
  await cb.press("Home");
  await expect(cb).toHaveAttribute("aria-activedescendant", /-o0$/);
  await cb.press("Escape");
});

test("combobox: placeholder when nothing is selected", async ({ page }) => {
  await open(page, "themes");
  const cb = main(page).getByRole("combobox", { name: "Optional choice" });
  await expect(cb).toHaveValue("");
  await expect(cb).toHaveAttribute("placeholder", "Pick a color");
  await expect(page.getByText("optional: none")).toBeVisible();
  await rerun(page, async () => { await cb.click(); await listbox(page).getByRole("option", { name: "Green" }).click(); });
  await expect(page.getByText("optional: Green")).toBeVisible();
});

test("multiselect: chips, max selections, backspace, clear all", async ({ page }) => {
  await open(page, "themes");
  const cb = main(page).getByRole("combobox", { name: "Multiselect" });
  const chips = main(page).locator(".st-multi .chip");
  await expect(chips).toHaveCount(2);
  await cb.click();
  await expect(listbox(page)).toHaveAttribute("aria-multiselectable", "true");
  await rerun(page, () => listbox(page).getByRole("option", { name: "Python" }).click());
  await expect(chips).toHaveCount(3);
  await expect(page.locator("#stPopups")).toContainText("Maximum reached (3)");
  await expect(listbox(page).getByRole("option", { name: "Go" })).toHaveAttribute("aria-disabled", "true");
  // list stays open while picking; clicking a chosen option removes it
  await rerun(page, () => listbox(page).getByRole("option", { name: "D" }).click());
  await expect(chips).toHaveCount(2);
  await rerun(page, () => cb.press("Backspace"));
  await expect(chips).toHaveCount(1);
  await cb.press("Escape");
  await rerun(page, () => main(page).getByRole("button", { name: "Clear all" }).click());
  await expect(chips).toHaveCount(0);
});

test("date picker: calendar, min/max, month navigation, keyboard, typing", async ({ page }) => {
  await open(page, "themes");
  await main(page).getByRole("button", { name: "Open calendar" }).click();
  const cal = page.locator("#stPopups [role=dialog]");
  await expect(cal.getByRole("grid")).toBeVisible();
  await expect(cal.locator('[data-date="2024-05-17"]')).toHaveAttribute("aria-selected", "true");
  await expect(cal.locator('[data-date="2024-05-02"]')).toBeDisabled();   // before minValue
  await expect(cal.locator('[data-date="2024-05-03"]')).toBeEnabled();
  await cal.getByRole("button", { name: "Next month" }).click();
  await expect(cal.locator('[data-date="2024-06-21"]')).toBeDisabled();   // after maxValue
  await cal.getByRole("button", { name: "Previous month" }).click();
  // keyboard: the selected day has focus; ArrowRight + Enter picks the 18th
  await cal.locator('[data-date="2024-05-17"]').focus();
  await page.keyboard.press("ArrowRight");
  await expect(cal.locator('[data-date="2024-05-18"]')).toBeFocused();
  await rerun(page, () => page.keyboard.press("Enter"));
  await expect(page.getByText("date: 2024-05-18")).toBeVisible();
  // typing a date out of range is rejected, a valid one is accepted
  const inp = main(page).getByLabel("Date", { exact: true });
  await inp.fill("2030-01-01");
  await inp.press("Enter");
  await expect(inp).toHaveValue("2024-05-18");
  await rerun(page, async () => { await inp.fill("2024-06-01"); await inp.press("Enter"); });
  await expect(page.getByText("date: 2024-06-01")).toBeVisible();
});

test("time picker: stepped list, filtering, typing", async ({ page }) => {
  await open(page, "themes");
  const inp = main(page).getByLabel("Time", { exact: true });
  await inp.click();
  await expect(listbox(page).getByRole("option", { name: "09:45" })).toBeVisible();     // 15-minute steps
  await expect(listbox(page).getByRole("option", { name: "09:40" })).toHaveCount(0);
  await rerun(page, () => listbox(page).getByRole("option", { name: "09:45" }).click());
  await expect(page.getByText("time: 09:45")).toBeVisible();
  await inp.click();
  await inp.fill("14:");
  await expect(listbox(page).getByRole("option")).toHaveCount(4);
  await rerun(page, async () => { await inp.fill("14:07"); await inp.press("Enter"); });
  await expect(page.getByText("time: 14:07")).toBeVisible();
});

test("color picker: hex entry, swatches, Escape cancels", async ({ page }) => {
  await open(page, "themes");
  await rerun(page, () => setColor(page, "Color", "#123456"));
  await expect(page.getByText("color: #123456")).toBeVisible();
  const sw = main(page).getByLabel("Color", { exact: true });
  await sw.click();
  await page.locator("#stPopups").getByLabel("Hex color").fill("#abcdef");
  await page.keyboard.press("Escape");
  await expect(main(page).locator(".st-color-hex")).toHaveText("#123456");
  await sw.click();
  await expect(page.locator("#stPopups .st-color-chip").first()).toBeVisible();
  await expect(page.locator("#stPopups .st-color-area")).toHaveAttribute("role", "slider");
});

test("popups are never clipped: dialog, sidebar, settings panel", async ({ page }) => {
  await open(page, "themes");
  const onTop = async (loc) => {
    const ok = await loc.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const top = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(20, r.height / 2));
      return el.contains(top) && r.bottom <= innerHeight + 1 && r.right <= innerWidth + 1 && r.left >= -1;
    });
    expect(ok).toBe(true);
  };
  // inside a dialog (which clips its content)
  await rerun(page, () => page.getByRole("button", { name: "Open dialog" }).click());
  // sidebar combobox opens over the main area
  await page.getByRole("dialog").press("Escape").catch(() => {});
  await page.keyboard.press("Escape");
  await page.getByTestId("st-sidebar").getByRole("combobox", { name: "Design style" }).click();
  await onTop(listbox(page));
  expect(await listbox(page).getByRole("option").count()).toBe(8);
  await page.keyboard.press("Escape");
  // settings panel list stays open while the panel is open, and is fully visible
  await page.getByTestId("st-settings").click();
  await page.getByTestId("st-design-select").click();
  await onTop(listbox(page));
  await listbox(page).getByRole("option", { name: /Brutalist/ }).click();
  await expect(page.locator("html")).toHaveAttribute("data-design", "brutalist");
  await expect(page.locator("#stSettingsPanel")).toBeVisible(); // choosing in the popup does not close the panel
});
