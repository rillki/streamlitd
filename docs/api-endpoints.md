# JSON API endpoints (FastAPI-style)

A streamlitd app can serve its own HTTP endpoints next to the UI: a JSON API for other services,
webhooks, a CSV export, a metrics feed. They run in the same binary, on the same port and base
path, and they can use the app's login, secrets, config and caches.

The API itself is built with **vibe.d's REST generator** (`vibe.web.rest`), which streamlitd already
depends on. Like FastAPI, you declare typed methods and get routing, JSON in and out, and `400`
answers for missing or malformed parameters. streamlitd adds the mounting, the login integration,
an [OpenAPI document and Swagger UI](#openapi-and-swagger-ui) (when you switch them on) and the
documentation here; it is not a separate API framework.

## A minimal API

<!-- compile -->
```d
import streamlitd;
import vibe.web.rest; // @path, @method, @before, @viaQuery, ...

struct Item { long id; string name; double price; }

@path("/api")
interface ItemsApi
{
@safe:
	@path("/items/:id") @method(HTTPMethod.GET)
	Item get(long _id);                         // GET  /api/items/7

	@path("/items") @method(HTTPMethod.POST)
	Item create(string name, double price);     // POST /api/items  {"name": "Pen", "price": 1.5}
}

class Items : ItemsApi
{
@safe:
	Item get(long id)
	{
		if (id != 7)
			throw new HTTPStatusException(HTTPStatus.notFound, "no such item");
		return Item(7, "Pen", 1.5);
	}

	Item create(string name, double price)
	{
		if (price < 0)
			throw new HTTPStatusException(HTTPStatus.badRequest, "price must be >= 0");
		return Item(8, name, price);
	}
}

void routes(URLRouter r)
{
	r.registerApi(new Items); // registerRestInterface + OpenAPI description
}

void app(St st)
{
	st.title("Shop");
}

mixin StreamlitMain!(app, routes);
```

`mixin StreamlitMain!(app, routes)` calls `routes` once at startup. Everything you register on the
router is served under the app's base path (`[server] baseUrlPath`), before the app's page:

```sh
curl localhost:8501/api/items/7                  # {"id":7,"name":"Pen","price":1.5}
curl -X POST localhost:8501/api/items -H 'Content-Type: application/json' -d '{"name":"Cup","price":3}'
curl localhost:8501/api/items/x                  # 400 {"statusMessage":"Unexpected 'x' when converting ..."}
```

The [`examples/api`](../examples/api) app is a complete version: a todo list with list, get,
create, update and delete endpoints, a plain handler, and a dashboard that shows the same data.

## FastAPI → streamlitd

| FastAPI | streamlitd / vibe.d |
|---|---|
| `app = FastAPI()` | `void routes(URLRouter r)` + `mixin StreamlitMain!(app, routes)` |
| `@app.get("/items/{id}")` | `@path("/items/:id") @method(HTTPMethod.GET)` on an interface method; the parameter is named `_id` |
| query parameter `q: str \| None = None` | a method parameter (`string q = null`); on GET methods, parameters come from the query string. Rename with `@viaQuery("q")` |
| request body model (`Item: BaseModel`) | parameters of a POST/PUT/PATCH method are the JSON body's fields; or a single struct parameter with `@viaBody` |
| `response_model=Item` | the method's return type (structs, arrays, `Json`, ...) is serialized to JSON |
| type validation → 422 | wrong or missing parameters → **400** with `{"statusMessage": ...}` |
| `raise HTTPException(404, "...")` | `throw new HTTPStatusException(HTTPStatus.notFound, "...")` |
| header parameter | `@viaHeader("X-Token")` on the parameter |
| `Depends(get_current_user)` | `@before!requireUser("user")` and a `UserInfo user` parameter |
| a raw `Request` handler | `r.get("/path", (HTTPServerRequest req, HTTPServerResponse res) { res.writeJsonBody(...); })` |
| `CORSMiddleware(allow_origins=[...])` | `auto s = new RestInterfaceSettings; s.allowedOrigins = [...]; r.registerRestInterface(impl, s);` |
| auto-generated Python client | `new RestInterfaceClient!ItemsApi("http://host:8501/")`, a typed D client from the same interface |
| `/docs` (Swagger UI), `/openapi.json` | `r.registerApi(impl)` and `[api] docs = true` ([see below](#openapi-and-swagger-ui)); off by default |
| `FastAPI(docs_url=, openapi_url=, title=, version=)` | `[api] docsPath`, `specPath`, `title`, `version` |
| `@app.get(..., summary=, description=)` | `@apiDoc("summary", "description")` on the interface method |

Method names without `@method` follow vibe.d's naming rules: `getItems` is `GET /items`,
`addItem`/`createItem`/`postItem` is `POST`, `updateItem`/`patchItem` is `PATCH`, `setItem`/`putItem` is `PUT`,
and `removeItem`/`deleteItem` is `DELETE`. Explicit `@path` and `@method` are clearer.

REST methods must be `@safe` (put `@safe:` at the top of the interface and the class). Call
`@system` code from a small `@trusted` function.

## Login and access control

API routes share the streamlitd login cookie, so a browser that is signed in to the app is also
signed in to its API.

- With `[auth] required = true`, every route you register answers **401** to requests without a
  login. There is nothing to add.
- `requireUser(req, res)` returns the user, or answers 401. `apiUser(req, res)` returns the user,
  or a `UserInfo` whose `isLoggedIn` is `false`.
- `requireRole(req, res, "admin")` also answers 403 unless the user has the role
  ([roles](authentication.md#roles)); `user.roles`, `user.hasRole(...)` work as in the app.
- `accounts()` is the account service (create users, roles, invites; [Authentication](authentication.md#accounts-from-code)).
- Errors from your routes have one shape: an `HTTPStatusException` thrown in a plain handler
  (including the one from `requireUser`) is answered as `{"statusMessage": "..."}`, like REST errors.
- Both work as vibe.d `@before` filters:

<!-- no-compile -->
```d
@path("/me") @method(HTTPMethod.GET) @before!requireUser("user")
Json me(UserInfo user);
```

Requests that change data (POST, PUT, PATCH, DELETE) and carry the login cookie must come from the
app's own origin or one listed in `[server] allowedOrigins` / `--allowed-origin`; others get **403**.
This is the same check that protects the app's WebSocket and uploads, and together with the cookie's
`SameSite=Lax` it stops other sites from acting with a signed-in browser. Requests without an
`Origin` header (curl, other services) and requests without the cookie are not affected.
Service-to-service calls usually use a token instead; read it from a header
(`@viaHeader("Authorization")`) and compare it with a value from `secrets.toml`.

CORS preflights (`OPTIONS`) never carry cookies, so they are always let through to vibe.d's
handler, which answers them from `RestInterfaceSettings.allowedOrigins`.

## Sharing data with the app

API handlers and app sessions run in the same process:

- `cacheData`/`cacheResource` caches are shared, so an endpoint can reuse the data the dashboard loaded.
- `secrets()` and the configuration are available everywhere.
- Module-level data that both sides change needs a lock, because sessions may run on worker
  threads (`[server] scriptThreads`). `examples/api` uses a `Mutex`.
- `st.session` and widgets exist only inside a session; an API request has no session.
- To update open pages after a request changed data, call `refreshFragments("topic")`: every
  fragment drawn with `refreshOn: "topic"` reruns at once, in every tab
  ([Updates driven by events](concepts.md#updates-driven-by-events)).

## OpenAPI and Swagger UI

streamlitd can describe the API as an **OpenAPI 3.0** document and serve **Swagger UI** for it, like
FastAPI's `/openapi.json` and `/docs`. Both are **off by default**.

**1. Register interfaces with `registerApi`** instead of `registerRestInterface`. It registers the
same routes and also describes them, from the D types, at compile time:

<!-- no-compile -->
```d
@path("/api")
interface ItemsApi
{
@safe:
	@path("/items/:id") @method(HTTPMethod.GET) @apiDoc("Get an item", "Answers 404 for unknown ids.")
	Item get(long _id);
}

void routes(URLRouter r)
{
	r.registerApi(new Items);                 // optional 3rd argument: RestInterfaceSettings
}
```

**2. Switch it on**, in any of these ways (CLI > environment > config file):

```toml
# .streamlitd/config.toml
[api]
docs = true                  # off by default
docsPath = "/docs"           # Swagger UI
specPath = "/openapi.json"   # the OpenAPI document
title = "Items API"          # info.title
version = "1.2.0"            # info.version
```

```sh
STREAMLITD_API_DOCS=true ./myapp     # also 1/yes/on; STREAMLITD_API_TITLE, _VERSION, _DOCSPATH, _SPECPATH
./myapp --api-docs                   # --api-docs=false turns it off again
```

The startup banner then shows the address, e.g. `http://localhost:8501/docs`. Both paths are under
the base path, so behind `--base-url-path /app` they are `/app/docs` and `/app/openapi.json`.

**What is described**

| D | OpenAPI |
|---|---|
| `@path` / `@method` routes, `:id` placeholders | `paths`, `{id}` path parameters |
| query and `@viaQuery` / `@viaHeader` parameters | `in: query` / `in: header`; required unless they have a default value |
| body parameters of POST/PUT/PATCH methods | one JSON object `requestBody`; fields without a default are `required` (if all have defaults, the body itself is optional) |
| a `@viaBody` parameter | the whole `requestBody` |
| return type | the `200` response schema |
| structs and classes | `components/schemas`, with vibe.d's `@name`, `@optional`, `@embedNullable` (optional), `@ignore` and `@byName`; nested and recursive types work. Two types with the same name get `Item`, `Item_2`, ... (`Error` is taken by streamlitd's error schema) |
| `Nullable!T` (also `Nullable!(T, nullValue)`), `T[]`, `V[string]`, enums, `Typedef!T` | `nullable`, `array`, `additionalProperties`, `enum`, the schema of `T` |
| integers, unsigned integers, `Date`/`SysTime`, `UUID` | `int32`/`int64` (unsigned: `minimum: 0`, `uint` as `int64`), `string` with `date`/`date-time`/`uuid` |
| `Json`, types with `toJson`/`fromJson` | any value |
| errors | `400` and `default` responses with the `Error` schema `{"statusMessage": "..."}` |
| `@apiDoc("summary", "description")` | `summary`, `description` (D doc comments are not available at compile time) |
| the interface name | the operation's tag |
| `@before` parameters such as `UserInfo user` | left out: they are not sent by the client |

Plain handlers (`r.get("/api/stats", ...)`) and interfaces registered with `registerRestInterface`
are listed too, under the tag `other`, with their method and path but without schemas. A route
registered with `r.any(...)` appears for the methods OpenAPI knows (GET, PUT, POST, DELETE, PATCH,
HEAD, TRACE), not for WebDAV methods such as PROPFIND.

**Login.** With `[auth]` configured, the document declares the login cookie as a security scheme;
with `required = true` it applies to every operation, and the document and Swagger UI themselves
need a login (Swagger UI redirects to the login page). Swagger UI sends the browser's cookie, so
"Try it out" works once you are signed in to the app.

**Compiling it out.** The generator and the embedded Swagger UI (about 1.7 MB) can be left out of the
binary with a dub version in the app's `dub.json`:

```json
"versions": ["StreamlitdNoApiDocs"]
```

`registerApi` then only registers the routes, `apiDocsCompiledIn` is `false`, and switching the docs
on at runtime prints a warning instead. Swagger UI is bundled for offline use (swagger-ui-dist,
Apache-2.0; see [assets/vendor/licenses](../assets/vendor/licenses/README.md)).

## Reserved paths

These paths belong to streamlitd. Registering a route under them, or a catch-all `*`, stops the
app at startup with an error: `/_stcore`, `/static`, `/_media`, `/_components`, `/_upload`, `/auth`,
`/oauth2callback` and `/favicon.ico`. When the API docs are on, `[api] docsPath` and `specPath`
(`/docs` and `/openapi.json` by default) are reserved too; they must be plain paths, differ from each
other and not be under the prefixes above (otherwise the app stops at startup with an error).

Put your endpoints under a prefix such as `/api/`. Every other path serves the app page, and multipage
apps use paths such as `/reports` for their pages (`Page` `urlPath`); a route with the same path
would take that page's URL over.

## What is not included

streamlitd covers the basics of a JSON API. It is not a replacement for a full API framework:

- **OpenAPI is generated from the D types**, not from validation rules: constraints such as
  "1 to 200 characters" go into `@apiDoc` text. Plain handlers appear without schemas.
- **No dependency injection** beyond `@before` filters, and **no background-task queue**: start a
  vibe.d task (`runTask`) for fire-and-forget work.
- **Validation is by type.** Range checks and similar rules go in the method body.

If a service is only an API, with no UI, a plain vibe.d application with `registerRestInterface` is
the simpler choice.
