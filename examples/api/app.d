/// A dashboard and a JSON API in one binary, on one port.
///   curl localhost:8501/api/todos
///   curl -X POST localhost:8501/api/todos -H 'Content-Type: application/json' -d '{"title":"Write docs"}'
///   curl -X DELETE localhost:8501/api/todos/1
/// Swagger UI: http://localhost:8501/docs ([api] docs = true in .streamlitd/config.toml)
import streamlitd;
import vibe.web.rest; // @path, @method, @before, @queryParam, ...
import core.sync.mutex : Mutex;
import std.algorithm : countUntil, filter, remove;
import std.array : array;
import std.string : strip;

// ---- the data, shared by the UI and the API ----

struct Todo
{
	long id;
	string title;
	bool done;
}

__gshared Todo[] g_todos;
__gshared long g_nextId = 1;
__gshared Mutex g_lock;

shared static this()
{
	g_lock = new Mutex;
	g_todos = [Todo(g_nextId++, "Try the API with curl", false)];
}

Todo[] allTodos() @trusted
{
	g_lock.lock();
	scope (exit) g_lock.unlock();
	return g_todos.dup;
}

Todo addTodo(string title, bool done) @trusted
{
	title = title.strip;
	if (title.length == 0 || title.length > 200)
		throw new HTTPStatusException(HTTPStatus.badRequest, "title must be 1 to 200 characters");
	g_lock.lock();
	scope (exit) g_lock.unlock();
	auto t = Todo(g_nextId++, title, done);
	g_todos ~= t;
	return t;
}

// ---- the API: a typed interface, routes and JSON are generated (like FastAPI's decorators) ----

@path("/api")
interface TodoApi
{
@safe:
	/// GET /api/todos?done=true
	@path("/todos") @method(HTTPMethod.GET) @apiDoc("List todos", "All todos, or only open/done ones with `?done=false` / `?done=true`.")
	Todo[] list(@viaQuery("done") string done = null);

	/// GET /api/todos/:id
	@path("/todos/:id") @method(HTTPMethod.GET) @apiDoc("Get one todo")
	Todo get(long _id);

	/// POST /api/todos  {"title": "...", "done": false}
	@path("/todos") @method(HTTPMethod.POST) @apiDoc("Create a todo", "`title` must be 1 to 200 characters.")
	Todo create(string title, bool done = false);

	/// PATCH /api/todos/:id  {"done": true}
	@path("/todos/:id") @method(HTTPMethod.PATCH) @apiDoc("Mark a todo done or open")
	Todo update(long _id, bool done);

	/// DELETE /api/todos/:id
	@path("/todos/:id") @method(HTTPMethod.DELETE) @apiDoc("Delete a todo")
	void remove(long _id);

	/// GET /api/me: the streamlitd login (if [auth] is configured)
	@path("/me") @method(HTTPMethod.GET) @before!apiUser("user") @apiDoc("The signed-in user", "Uses the app's login, if `[auth]` is configured.")
	Json me(UserInfo user);
}

class TodoService : TodoApi
{
@safe:
	Todo[] list(string done)
	{
		auto all = allTodos();
		if (done is null)
			return all;
		if (done != "true" && done != "false")
			throw new HTTPStatusException(HTTPStatus.badRequest, "done must be true or false");
		return all.filter!(t => t.done == (done == "true")).array;
	}

	Todo get(long id)
	{
		foreach (t; allTodos())
			if (t.id == id)
				return t;
		throw new HTTPStatusException(HTTPStatus.notFound, "no todo with id " ~ id.to!string);
	}

	Todo create(string title, bool done) { return addTodo(title, done); }

	Todo update(long id, bool done) @trusted
	{
		g_lock.lock();
		scope (exit) g_lock.unlock();
		auto i = g_todos.countUntil!(t => t.id == id);
		if (i < 0)
			throw new HTTPStatusException(HTTPStatus.notFound, "no todo with id " ~ id.to!string);
		g_todos[i].done = done;
		return g_todos[i];
	}

	void remove(long id) @trusted
	{
		g_lock.lock();
		scope (exit) g_lock.unlock();
		auto i = g_todos.countUntil!(t => t.id == id);
		if (i < 0)
			throw new HTTPStatusException(HTTPStatus.notFound, "no todo with id " ~ id.to!string);
		g_todos = g_todos.remove(i);
	}

	Json me(UserInfo user)
	{
		return Json(["loggedIn": Json(user.isLoggedIn), "name": user.isLoggedIn ? Json(user.name) : Json(null)]);
	}
}

import std.conv : to;

/// Extra HTTP routes, served next to the app (same port, base path and login).
void routes(URLRouter r)
{
	r.registerApi(new TodoService); // registerRestInterface + OpenAPI description (see /docs)
	// a plain handler, for anything that isn't a typed interface (webhooks, files, ...)
	r.get("/api/stats", (HTTPServerRequest req, HTTPServerResponse res) {
		auto all = allTodos();
		res.writeJsonBody(["total": all.length, "done": all.filter!(t => t.done).array.length]);
	});
}

// ---- the dashboard ----

void app(St st)
{
	st.setPageConfig(title: "Todos + API", icon: "✅");
	st.title("Todos");
	st.caption("The same list is served as JSON at `api/todos`. Change it with curl, then press Refresh.");

	with (st.form("add", clearOnSubmit: true))
	{
		auto title = textInput("New todo");
		if (formSubmitButton("Add", type: "primary") && title.strip.length)
			addTodo(title, false);
	}

	auto todos = allTodos();
	auto c = st.columns(2);
	c[0].metric("Total", todos.length);
	c[1].metric("Done", todos.filter!(t => t.done).array.length);
	if (todos.length)
		st.dataframe(DataFrame.fromStructs(todos), hideIndex: true);
	st.button("Refresh");
}

mixin StreamlitMain!(app, routes);
