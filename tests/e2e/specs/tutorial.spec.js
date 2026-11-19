const { test } = require("@playwright/test");
const { open, rerun, expect } = require("./helpers");

const metric = (page, label) =>
  page.getByTestId("st-metric").filter({ has: page.locator(".metric-label", { hasText: new RegExp("^" + label + "$") }) }).locator(".metric-value");

test("tutorial dashboard: filters, tabs, form, live fragment", async ({ page }) => {
  await open(page, "tutorial");
  await expect(page).toHaveTitle("Sales dashboard");
  await expect(metric(page, "Orders")).toHaveText("120");
  await expect(page.getByTestId("st-vega-lite")).toHaveCount(2);

  // filters
  await rerun(page, () => page.getByRole("button", { name: "Remove West" }).click());
  await expect(metric(page, "Orders")).toHaveText("90");
  await rerun(page, () => page.getByRole("button", { name: "Gizmo" }).click());
  const gizmo = +(await metric(page, "Orders").textContent());
  expect(gizmo).toBeGreaterThan(0);
  expect(gizmo).toBeLessThan(90);
  await rerun(page, () => page.getByRole("button", { name: "Gizmo" }).click()); // deselect

  // data tab
  await page.getByRole("tab", { name: "🗂 Data" }).click();
  const table = page.getByTestId("st-dataframe");
  await expect(table.locator("tbody tr")).toHaveCount(90);
  // column formats and the totals row
  await expect(table.locator("tbody tr").first().locator("td").first()).toHaveText(/^\d\d\.\d\d\.\d{4}$/);
  await expect(table.locator("tbody tr").first().locator("td").last()).toHaveText(/^\$[\d,]+\.\d\d$/);
  await expect(table.locator("tfoot th")).toHaveText("Total");
  // the CSV is built when clicked
  const dl = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download CSV" }).click();
  const file = await dl;
  expect(file.suggestedFilename()).toBe("sales.csv");
  expect(require("fs").readFileSync(await file.path(), "utf8").split("\n")[0]).toBe("date,region,product,units,revenue");

  // form adds a row (North is still selected)
  await page.getByText("➕ Add a sale").click();
  await page.getByRole("spinbutton", { name: "Units" }).fill("25");
  await rerun(page, () => page.getByRole("button", { name: "Add", exact: true }).click());
  await expect(metric(page, "Orders")).toHaveText("91");
  await expect(page.getByTestId("st-toast")).toContainText("Added 25 × Widget");

  // live fragment ticks without full reruns changing the table
  const live = metric(page, "Live orders today");
  const v0 = +(await live.textContent());
  await expect.poll(async () => +(await live.textContent()), { timeout: 6000 }).toBeGreaterThan(v0);
});
