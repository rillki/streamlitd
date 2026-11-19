// Several people using one app at the same time: separate sessions, no shared widget state.
const { test } = require("@playwright/test");
const { open, rerun, widget, expect } = require("./helpers");

test("three users at once each keep their own values", async ({ browser }) => {
  const users = ["Ann", "Bob", "Cyd"];
  const pages = await Promise.all(users.map(async () => (await browser.newContext()).newPage()));
  await Promise.all(pages.map((p) => open(p, "hello")));
  // everybody types and clicks at the same time
  await Promise.all(pages.map((p, i) => rerun(p, async () => {
    const input = widget(p, "text_input", "Your name").locator("input");
    await input.fill(users[i]);
    await input.press("Enter");
  })));
  await Promise.all(pages.map((p) => rerun(p, () => p.getByRole("button", { name: "Greet" }).click())));
  for (const [i, p] of pages.entries()) {
    await expect(p.getByText(`Hello ${users[i]}!`)).toBeVisible();
    for (const other of users.filter((u) => u !== users[i])) await expect(p.getByText(`Hello ${other}!`)).toHaveCount(0);
  }
  // per-session state: clicks count separately
  await rerun(pages[0], () => pages[0].getByRole("button", { name: "Count clicks" }).click());
  await rerun(pages[0], () => pages[0].getByRole("button", { name: "Count clicks" }).click());
  await rerun(pages[1], () => pages[1].getByRole("button", { name: "Count clicks" }).click());
  await expect(pages[0].getByText("Clicks so far:")).toContainText("2");
  await expect(pages[1].getByText("Clicks so far:")).toContainText("1");
  await expect(pages[2].getByText("Clicks so far:")).toContainText("0");
  for (const p of pages) await p.context().close();
});
