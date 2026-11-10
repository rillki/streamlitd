const { test } = require("@playwright/test");
const SwaggerParser = require("@apidevtools/swagger-parser");
const { url, waitIdle, expect } = require("./helpers");

test("the OpenAPI document is valid and describes the REST interface", async ({ request }) => {
  const r = await request.get(url("api", "/openapi.json"));
  expect(r.status()).toBe(200);
  expect(r.headers()["content-type"]).toContain("application/json");
  const spec = await r.json();
  // a full OpenAPI 3 validation (structure and $refs); validate() mutates its argument
  await SwaggerParser.validate(JSON.parse(JSON.stringify(spec)));

  expect(spec.info).toEqual({ title: "Todos API", version: "1.0.0" });
  expect(Object.keys(spec.paths)).toEqual(["/api/todos", "/api/todos/{id}", "/api/me", "/api/stats"]);
  const list = spec.paths["/api/todos"].get;
  expect(list.summary).toBe("List todos");
  expect(list.parameters).toEqual([{ name: "done", in: "query", required: false, schema: { type: "string" } }]);
  expect(list.responses["200"].content["application/json"].schema).toEqual({ type: "array", items: { $ref: "#/components/schemas/Todo" } });
  const create = spec.paths["/api/todos"].post.requestBody.content["application/json"].schema;
  expect(create.required).toEqual(["title"]);
  expect(Object.keys(create.properties)).toEqual(["title", "done"]);
  expect(spec.paths["/api/todos/{id}"].delete.parameters[0]).toMatchObject({ name: "id", in: "path", required: true });
  expect(spec.components.schemas.Todo.properties.id).toEqual({ type: "integer", format: "int64" });
  // a plain handler is listed without a schema; the @before parameter is not a request parameter
  expect(spec.paths["/api/stats"].get.tags).toEqual(["other"]);
  expect(spec.paths["/api/me"].get.parameters).toBeUndefined();
  expect(spec.components.schemas.UserInfo).toBeUndefined();
});

test("Swagger UI lists the operations and runs one", async ({ page }) => {
  await page.goto(url("api", "/docs"));
  await expect(page).toHaveTitle("Todos API · API docs");
  const op = page.locator(".opblock-get").filter({ hasText: "List todos" }).first();
  await expect(op).toBeVisible();
  await expect(page.locator(".opblock-post").filter({ hasText: "Create a todo" })).toBeVisible();
  await op.locator(".opblock-summary").click();
  await op.getByRole("button", { name: "Try it out" }).click();
  await op.getByRole("button", { name: "Execute" }).click();
  await expect(op.locator(".live-responses-table tbody .response-col_status").first()).toHaveText("200");
  await expect(op.locator(".live-responses-table tbody .microlight").first()).toContainText("Try the API with curl");
});

test("API docs are off unless switched on", async ({ request }) => {
  // the /sub instance runs with --api-docs=false: the paths are the app's page again
  for (const p of ["/sub/openapi.json", "/sub/docs"]) {
    const r = await request.get(`http://127.0.0.1:8712${p}`);
    expect(r.headers()["content-type"]).toContain("text/html");
    expect(await r.text()).not.toContain("SwaggerUIBundle");
  }
  // apps that never switch them on (default off)
  const hello = await request.get(url("hello", "/openapi.json"));
  expect(hello.headers()["content-type"]).toContain("text/html");
});

test("API docs follow [auth] required", async ({ page, request }) => {
  // the auth app runs with STREAMLITD_API_DOCS=true
  const anon = await request.get(url("auth", "/openapi.json"));
  expect(anon.status()).toBe(401);
  await page.goto(url("auth", "/docs"));
  await expect(page).toHaveURL(/\/auth\/login$/);
  await page.getByLabel("Username").fill("alice");
  await page.getByLabel("Password").fill("secret123");
  await page.getByRole("button", { name: "Sign in" }).click();
  await waitIdle(page, 1);
  const spec = await (await page.request.get(url("auth", "/openapi.json"))).json();
  expect(spec.security).toEqual([{ streamlitdLogin: [] }]);
  expect(spec.components.securitySchemes.streamlitdLogin).toMatchObject({ type: "apiKey", in: "cookie", name: "streamlitd_auth" });
  expect(Object.keys(spec.paths)).toEqual(["/api/whoami"]);
  await page.goto(url("auth", "/docs"));
  await expect(page.locator(".opblock-get").filter({ hasText: "/api/whoami" })).toBeVisible();
});
