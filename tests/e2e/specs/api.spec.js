const { test } = require("@playwright/test");
const { url, open, rerun, waitIdle, expect } = require("./helpers");

test.describe.configure({ mode: "serial" }); // the specs share the api app's in-memory list

test("REST interface: CRUD and JSON errors", async ({ request }) => {
  const api = (p) => url("api", p);
  const created = await request.post(api("/api/todos"), { data: { title: "From Playwright" } });
  expect(created.status()).toBe(200);
  const todo = await created.json();
  expect(todo).toMatchObject({ title: "From Playwright", done: false });

  expect(await (await request.get(api(`/api/todos/${todo.id}`))).json()).toEqual(todo);
  const patched = await request.patch(api(`/api/todos/${todo.id}`), { data: { done: true } });
  expect((await patched.json()).done).toBe(true);
  const done = await (await request.get(api("/api/todos?done=true"))).json();
  expect(done.map((t) => t.id)).toContain(todo.id);

  // validation: missing field, wrong type, app-level check, unknown id, bad path parameter
  expect((await request.post(api("/api/todos"), { data: {} })).status()).toBe(400);
  expect((await request.post(api("/api/todos"), { data: { title: "x", done: "maybe" } })).status()).toBe(400);
  const blank = await request.post(api("/api/todos"), { data: { title: "   " } });
  expect(blank.status()).toBe(400);
  expect((await blank.json()).statusMessage).toContain("title");
  expect((await request.get(api("/api/todos/999999"))).status()).toBe(404);
  expect((await request.get(api("/api/todos/abc"))).status()).toBe(400);
  expect((await request.get(api("/api/todos?done=maybe"))).status()).toBe(400);

  // plain handler next to the interface
  const stats = await (await request.get(api("/api/stats"))).json();
  expect(stats.total).toBeGreaterThan(0);
  expect(await (await request.get(api("/api/me"))).json()).toEqual({ loggedIn: false, name: null });
  // CORS preflight reaches vibe.d's OPTIONS handler
  const pre = await request.fetch(api("/api/todos"), { method: "OPTIONS",
    headers: { Origin: "http://other.example", "Access-Control-Request-Method": "POST" } });
  expect(pre.status()).toBeLessThan(300);

  expect((await request.delete(api(`/api/todos/${todo.id}`))).status()).toBeLessThan(300);
  expect((await request.get(api(`/api/todos/${todo.id}`))).status()).toBe(404);
});

test("the dashboard and the API share data", async ({ page, request }) => {
  await open(page, "api");
  await request.post(url("api", "/api/todos"), { data: { title: "Added over HTTP" } });
  await rerun(page, () => page.getByRole("button", { name: "Refresh" }).click());
  await expect(page.getByText("Added over HTTP")).toBeVisible();

  await page.getByLabel("New todo").fill("Added in the UI");
  await rerun(page, () => page.getByRole("button", { name: "Add" }).click());
  const all = await (await request.get(url("api", "/api/todos"))).json();
  expect(all.map((t) => t.title)).toContain("Added in the UI");
});

test("API routes live under the base path", async ({ request }) => {
  const r = await request.get("http://127.0.0.1:8712/sub/api/todos");
  expect(r.status()).toBe(200);
  expect(Array.isArray(await r.json())).toBe(true);
  expect((await request.get("http://127.0.0.1:8712/api/todos")).status()).toBe(404);
});

test("API routes follow [auth] required and requireUser", async ({ page, request }) => {
  const anon = await request.get(url("auth", "/api/whoami"));
  expect(anon.status()).toBe(401);
  expect(await anon.json()).toEqual({ statusMessage: "login required" });
  await page.goto(url("auth", "/"));
  await page.getByLabel("Username").fill("alice");
  await page.getByLabel("Password").fill("streamlitd-demo");
  await page.getByRole("button", { name: "Sign in" }).click();
  await waitIdle(page, 1);
  const me = await page.request.get(url("auth", "/api/whoami"));
  expect(me.status()).toBe(200);
  expect(await me.json()).toMatchObject({ name: "Alice", email: "alice@example.com", provider: "password" });
});
