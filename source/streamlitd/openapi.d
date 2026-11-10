/// OpenAPI 3 documents and Swagger UI for the app's API endpoints (FastAPI's `/docs`).
///
/// `registerApi` registers a vibe.d REST interface (like `registerRestInterface`) and describes it:
/// paths, parameters, request bodies and response schemas are derived from the D interface at compile
/// time. Plain handlers (`r.get(...)`) appear with their method and path only.
///
/// Serving is switched on at runtime with `[api] docs = true`, `STREAMLITD_API_DOCS=true` or
/// `--api-docs` (off by default). Building with the dub version `StreamlitdNoApiDocs` removes the
/// generator and the embedded Swagger UI from the binary. See docs/api-endpoints.md.
module streamlitd.openapi;

import vibe.data.json;
import vibe.http.common : HTTPMethod;
import vibe.http.router : URLRouter;
import vibe.web.rest : RestInterfaceSettings, registerRestInterface;

import streamlitd.config : ApiDocsOptions;

/// True unless the app was built with the dub version `StreamlitdNoApiDocs`.
version (StreamlitdNoApiDocs)
	enum apiDocsCompiledIn = false;
else
	enum apiDocsCompiledIn = true;

/// Summary and description of an API method in the OpenAPI document (`@apiDoc("List todos")`).
struct ApiDoc
{
	string summary;
	string description;
}

/// ditto
ApiDoc apiDoc(string summary, string description = null) @safe pure nothrow
{
	return ApiDoc(summary, description);
}

/// Register a REST interface implementation (as vibe.d's `registerRestInterface` does) and add it
/// to the app's OpenAPI document. Use it inside the `routes` function of `StreamlitMain!(app, routes)`.
URLRouter registerApi(TImpl)(URLRouter router, TImpl impl, RestInterfaceSettings settings = null)
{
	router.registerRestInterface(impl, settings);
	version (StreamlitdNoApiDocs) {}
	else
		describeInterface!TImpl(settings, g_registry);
	return router;
}

/// A route of the app (method + router pattern), as seen by the server.
struct AppRoute
{
	HTTPMethod method;
	string pattern;
}

version (StreamlitdNoApiDocs) {} else version = StreamlitdApiDocs;
version (StreamlitdApiDocs):

import std.algorithm : canFind, startsWith, endsWith;
import std.array : replace;
import std.conv : to;
import std.string : toLower;

private struct DocOperation
{
	HTTPMethod method;
	string pattern; // router pattern, e.g. /api/todos/:_id
	string path;    // OpenAPI path, e.g. /api/todos/{id}
	Json op;
}

/// Operations and component schemas collected by `registerApi`.
struct ApiRegistry
{
	DocOperation[] operations;
	Json[string] schemas;      // component name -> schema
	string[string] typeNames;  // fully qualified D type -> component name
}

private ApiRegistry g_registry;

/// Forget everything `registerApi` recorded (a new `serve` starts from scratch).
package void resetApiRegistry() { g_registry = ApiRegistry.init; }

/// `/api/todos/:_id` → `/api/todos/{id}`.
string openApiPath(string pattern) @safe pure
{
	import std.array : split, join;
	auto parts = pattern.split("/");
	foreach (ref p; parts)
		if (p.startsWith(":"))
		{
			auto n = p[1 .. $];
			if (n.startsWith("_"))
				n = n[1 .. $];
			p = "{" ~ n ~ "}";
		}
	return parts.join("/");
}

private string jsonFieldName(string m) @safe pure
{
	// vibe.d strips one trailing underscore (keywords: `version_`, `body_`)
	return m.length > 1 && m.endsWith("_") ? m[0 .. $ - 1] : m;
}

/// Component schema names used by streamlitd itself.
private immutable string[] builtinSchemas = ["Error"];

/// The component name for `T`: its D name, with a suffix when another type already has that name.
private string componentName(T)(ref ApiRegistry reg, out bool known)
{
	import std.algorithm : canFind;
	import std.ascii : isAlphaNum;
	import std.traits : fullyQualifiedName;
	enum fqn = fullyQualifiedName!T;
	if (auto n = fqn in reg.typeNames)
	{
		known = true;
		return *n;
	}
	string base;
	foreach (c; T.stringof)
		base ~= isAlphaNum(c) ? c : '_';
	auto n = base;
	for (int i = 2; (n in reg.schemas) !is null || builtinSchemas.canFind(n); i++)
		n = base ~ "_" ~ i.to!string;
	reg.typeNames[fqn] = n;
	return n;
}

/// vibe.d writes such types with their `toJson()` (vibe's own trait is package-private).
private enum hasToJson(T) = is(typeof(T.init.toJson()) : Json) && is(typeof(T.fromJson(Json())) : T);

/// JSON schema of how vibe.d serializes `T` (checked in the serializer's order); structs and classes
/// go to `reg.schemas` and are referenced.
Json schemaOf(T)(ref ApiRegistry reg)
{
	import std.datetime : Date, DateTime, SysTime, TimeOfDay;
	import std.range : ElementType;
	import std.traits;
	import std.typecons : Nullable, Typedef, TypedefType;
	import std.uuid : UUID;
	import vibe.data.serialization : isCustomSerializable, isISOExtStringSerializable, isStringSerializable;

	static Json typed(string t, string format = null)
	{
		auto j = Json.emptyObject;
		j["type"] = t;
		if (format.length)
			j["format"] = format;
		return j;
	}

	alias U = Unqual!T;
	static if (is(U == Nullable!TPS, TPS...))
	{
		auto inner = schemaOf!(typeof(U.init.get()))(reg);
		if ("$ref" in inner)
		{
			auto j = Json.emptyObject;
			j["allOf"] = Json([inner]);
			j["nullable"] = true;
			return j;
		}
		inner["nullable"] = true;
		return inner;
	}
	else static if (is(U == Json))
		return Json.emptyObject; // any JSON value
	else static if (isInstanceOf!(Typedef, U))
		return schemaOf!(TypedefType!U)(reg);
	else static if (is(U == enum))
	{
		auto j = schemaOf!(OriginalType!U)(reg);
		auto values = Json.emptyArray;
		foreach (m; EnumMembers!U)
			values ~= Json(cast(OriginalType!U) m);
		j["enum"] = values;
		return j;
	}
	else static if (is(U == UUID))
		return typed("string", "uuid");
	else static if (hasToJson!U)
		return Json.emptyObject; // toJson(): any JSON value
	else static if (is(U == bool))
		return typed("boolean");
	else static if (isIntegral!U)
	{
		auto j = typed("integer", U.sizeof > 4 || (isUnsigned!U && U.sizeof == 4) ? "int64" : "int32");
		static if (isUnsigned!U)
			j["minimum"] = 0;
		return j;
	}
	else static if (isFloatingPoint!U)
		return typed("number", is(U == float) ? "float" : "double");
	else static if (isSomeString!U || isSomeChar!U)
		return typed("string");
	else static if (is(U : const(ubyte)[]))
		return typed("string", "byte"); // base64
	else static if (isCustomSerializable!U)
		return schemaOf!(typeof(U.init.toRepresentation()))(reg);
	else static if (isISOExtStringSerializable!U)
	{
		static if (is(U == Date)) return typed("string", "date");
		else static if (is(U == TimeOfDay)) return typed("string", "time");
		else static if (is(U == DateTime) || is(U == SysTime)) return typed("string", "date-time");
		else return typed("string");
	}
	else static if (isStringSerializable!U)
		return typed("string");
	else static if (isArray!U)
	{
		auto j = typed("array");
		j["items"] = schemaOf!(ElementType!U)(reg);
		return j;
	}
	else static if (isAssociativeArray!U)
	{
		auto j = typed("object");
		j["additionalProperties"] = schemaOf!(ValueType!U)(reg);
		return j;
	}
	else static if (is(U == struct) || is(U == class))
	{
		bool known;
		auto name = componentName!U(reg, known);
		auto refj = Json.emptyObject;
		refj["$ref"] = "#/components/schemas/" ~ name;
		if (known)
			return refj;
		reg.schemas[name] = Json.emptyObject; // placeholder: breaks cycles
		auto props = Json.emptyObject;
		props[orderKey] = Json.emptyArray;
		auto required = Json.emptyArray;
		structFields!U(reg, props, required);
		auto j = typed("object");
		j["properties"] = props;
		if (required.length)
			j["required"] = required;
		reg.schemas[name] = j;
		return refj;
	}
	else
		return Json.emptyObject;
}

private void structFields(T)(ref ApiRegistry reg, ref Json props, ref Json required)
{
	import std.traits : hasUDA, getUDAs;
	import vibe.data.serialization : NameAttribute, OptionalAttribute, IgnoreAttribute, ByNameAttribute,
		EmbedNullableIgnoreNullAttribute;
	import vibe.internal.meta.traits : isRWPlainField, isRWField;

	static foreach (m; __traits(allMembers, T))
	{{
		static if (isRWPlainField!(T, m) || isRWField!(T, m))
		{
			alias sym = __traits(getMember, T, m);
			static if (!hasUDA!(sym, IgnoreAttribute))
			{
				alias FT = typeof(__traits(getMember, T.init, m));
				static if (hasUDA!(sym, NameAttribute))
					enum fname = getUDAs!(sym, NameAttribute)[0].name;
				else
					enum fname = jsonFieldName(m);
				Json s;
				static if (is(FT == enum) && hasUDA!(sym, ByNameAttribute))
				{
					s = Json.emptyObject;
					s["type"] = "string";
					auto names = Json.emptyArray;
					foreach (e; __traits(allMembers, FT))
						names ~= Json(e);
					s["enum"] = names;
				}
				else
					s = schemaOf!FT(reg);
				props[fname] = s;
				props[orderKey] ~= Json(fname);
				static if (!hasUDA!(sym, OptionalAttribute) && !hasUDA!(sym, EmbedNullableIgnoreNullAttribute)) // as vibe.d
					required ~= Json(fname);
			}
		}
	}}
}

private Json errorResponse(string description)
{
	auto r = Json.emptyObject;
	r["description"] = description;
	auto ref_ = Json.emptyObject;
	ref_["$ref"] = "#/components/schemas/Error";
	r["content"] = Json(["application/json": Json(["schema": ref_])]);
	return r;
}

/// Describe every route of a REST interface implementation into `reg`.
void describeInterface(TImpl)(RestInterfaceSettings settings, ref ApiRegistry reg)
{
	import std.traits : ParameterIdentifierTuple, ParameterDefaults, Parameters, ReturnType, getUDAs;
	import vibe.web.internal.rest.common : RestInterface, ParameterKind;

	auto intf = RestInterface!TImpl(settings, false);
	alias I = intf.I;
	enum tag = I.stringof;

	static foreach (i, F; intf.RouteFunctions)
	{{
		auto route = intf.routes[i];
		auto op = Json.emptyObject;
		op["operationId"] = route.functionName;
		op["tags"] = Json([Json(tag)]);
		alias docs = getUDAs!(F, ApiDoc);
		static if (docs.length)
		{
			if (docs[0].summary.length) op["summary"] = docs[0].summary;
			if (docs[0].description.length) op["description"] = docs[0].description;
		}

		alias PTypes = Parameters!F;
		alias PNames = ParameterIdentifierTuple!F;
		alias PDefaults = ParameterDefaults!F;
		auto params = Json.emptyArray;
		auto bodyProps = Json.emptyObject;
		bodyProps[orderKey] = Json.emptyArray;
		auto bodyRequired = Json.emptyArray;
		Json wholeBody;
		foreach (p; route.parameters)
		{
			static foreach (j; 0 .. PTypes.length)
			{{
				if (p.name == PNames[j])
				{
					enum hasDefault = !is(PDefaults[j] == void);
					Json schema()
					{
						return schemaOf!(PTypes[j])(reg);
					}
					final switch (p.kind)
					{
						case ParameterKind.query:
						case ParameterKind.header:
						case ParameterKind.internal:
						{
							auto pj = Json.emptyObject;
							auto pname = p.fieldName.length ? p.fieldName : p.name;
							if (p.kind == ParameterKind.internal && pname.startsWith("_"))
								pname = pname[1 .. $];
							pj["name"] = pname;
							pj["in"] = p.kind == ParameterKind.query ? "query" : p.kind == ParameterKind.header ? "header" : "path";
							pj["required"] = p.kind == ParameterKind.internal || !hasDefault;
							pj["schema"] = schema();
							params ~= pj;
							break;
						}
						case ParameterKind.body_:
						{
							auto fname = p.fieldName.length ? p.fieldName : p.name;
							bodyProps[fname] = schema();
							bodyProps[orderKey] ~= Json(fname);
							if (!hasDefault)
								bodyRequired ~= Json(fname);
							break;
						}
						case ParameterKind.wholeBody:
							wholeBody = schema();
							break;
						case ParameterKind.attributed:
						case ParameterKind.auth:
						case ParameterKind.status:
							break;
					}
				}
			}}
		}
		if (params.length)
			op["parameters"] = params;
		if (wholeBody.type != Json.Type.undefined || bodyProps.length > 1)
		{
			Json schema = wholeBody;
			if (schema.type == Json.Type.undefined)
			{
				schema = Json.emptyObject;
				schema["type"] = "object";
				schema["properties"] = bodyProps;
				if (bodyRequired.length)
					schema["required"] = bodyRequired;
			}
			auto rb = Json.emptyObject;
			rb["required"] = wholeBody.type != Json.Type.undefined || bodyRequired.length > 0; // all defaults: optional
			rb["content"] = Json(["application/json": Json(["schema": schema])]);
			op["requestBody"] = rb;
		}

		auto responses = Json.emptyObject;
		alias R = ReturnType!F;
		auto ok = Json.emptyObject;
		ok["description"] = "Successful response";
		static if (!is(R == void))
			ok["content"] = Json(["application/json": Json(["schema": schemaOf!R(reg)])]);
		responses["200"] = ok;
		responses["400"] = errorResponse("Invalid parameters");
		responses["default"] = errorResponse("Error");
		op["responses"] = responses;

		reg.operations ~= DocOperation(route.method, route.fullPattern, openApiPath(route.fullPattern), op);
	}}
}

private string methodKey(HTTPMethod m)
{
	return m.to!string.toLower;
}

/// The HTTP methods an OpenAPI 3.0 path item can describe (`r.any` also registers WebDAV methods).
private bool isOpenApiMethod(HTTPMethod m) @safe pure nothrow
{
	with (HTTPMethod) switch (m)
	{
		case GET, PUT, POST, DELETE, PATCH, HEAD, OPTIONS, TRACE: return true;
		default: return false;
	}
}

/// Build the OpenAPI 3.0 document: the `registerApi` operations plus every other app route.
string buildOpenApiSpec(const ApiDocsOptions opts, string basePath, const AppRoute[] routes,
	bool authEnabled, bool authRequired, const ref ApiRegistry reg = g_registry)
{
	auto doc = Json.emptyObject;
	doc["openapi"] = "3.0.3";
	doc["info"] = Json(["title": Json(opts.title), "version": Json(opts.version_)]);
	doc["servers"] = Json([Json(["url": Json(basePath.length ? basePath : "/")])]);

	auto paths = Json.emptyObject;
	paths[orderKey] = Json.emptyArray; // registration order, like FastAPI
	bool[string] ids;
	bool[string] documented;
	void put(string path, HTTPMethod m, Json op)
	{
		auto id = op["operationId"].get!string;
		for (int n = 2; id in ids; n++)
			id = op["operationId"].get!string ~ "_" ~ n.to!string;
		ids[id] = true;
		op["operationId"] = id;
		if (paths[path].type != Json.Type.object)
		{
			paths[path] = Json.emptyObject;
			paths[orderKey] ~= Json(path);
		}
		paths[path][methodKey(m)] = op;
	}
	foreach (o; reg.operations)
	{
		documented[methodKey(o.method) ~ " " ~ o.pattern] = true;
		put(o.path, o.method, o.op.clone);
	}
	foreach (r; routes)
	{
		if (r.method == HTTPMethod.OPTIONS || !isOpenApiMethod(r.method) || r.pattern.canFind("*") || (methodKey(r.method) ~ " " ~ r.pattern) in documented)
			continue;
		auto op = Json.emptyObject;
		auto path = openApiPath(r.pattern);
		auto id = methodKey(r.method) ~ path.replace("/", "_").replace("{", "").replace("}", "").replace("-", "_").replace(".", "_");
		op["operationId"] = id;
		op["summary"] = r.method.to!string ~ " " ~ path;
		op["tags"] = Json([Json("other")]);
		auto params = Json.emptyArray;
		import std.array : split;
		foreach (seg; path.split("/"))
			if (seg.startsWith("{"))
				params ~= Json(["name": Json(seg[1 .. $ - 1]), "in": Json("path"), "required": Json(true),
					"schema": Json(["type": Json("string")])]);
		if (params.length)
			op["parameters"] = params;
		op["responses"] = Json(["default": Json(["description": Json("Response (not described: a plain handler)")])]);
		put(path, r.method, op);
	}
	doc["paths"] = paths;

	auto schemas = Json.emptyObject;
	foreach (k, v; reg.schemas)
		schemas[k] = v;
	schemas["Error"] = Json(["type": Json("object"), "required": Json([Json("statusMessage")]),
		"properties": Json(["statusMessage": Json(["type": Json("string")])])]);
	auto components = Json.emptyObject;
	components["schemas"] = schemas;
	if (authEnabled)
	{
		import streamlitd.authserver : authCookie;
		components["securitySchemes"] = Json(["streamlitdLogin": Json(["type": Json("apiKey"), "in": Json("cookie"),
			"name": Json(authCookie), "description": Json("The streamlitd login cookie: sign in to the app in this browser first.")])]);
		if (authRequired)
			doc["security"] = Json([Json(["streamlitdLogin": Json.emptyArray])]);
	}
	doc["components"] = components;
	return toOrderedJson(doc);
}

/// Objects may carry this key: the order of their other keys (it is not written out).
private enum orderKey = "\x01order";

// fixed order for well-known OpenAPI keys; anything else follows, alphabetically
private immutable string[] keyOrder = ["openapi", "info", "title", "version", "servers", "url", "security", "paths",
	"get", "put", "post", "patch", "delete", "head", "options", "tags", "summary", "description", "operationId",
	"name", "in", "required", "parameters", "requestBody", "responses", "200", "400", "default", "content",
	"application/json", "schema", "$ref", "allOf", "type", "format", "nullable", "enum", "items", "properties",
	"additionalProperties", "components", "schemas", "securitySchemes"];

/// Pretty JSON with a stable, readable key order (vibe's `Json` objects don't keep insertion order).
string toOrderedJson(Json j)
{
	import std.algorithm : countUntil, sort;
	import std.array : appender;
	auto app = appender!string;
	void write(Json v, size_t indent)
	{
		string pad(size_t n) { import std.array : replicate; return "  ".replicate(n); }
		switch (v.type)
		{
			case Json.Type.object:
				string[] keys;
				if (auto ord = orderKey in v)
					foreach (k; *ord)
						keys ~= k.get!string;
				string[] rest;
				foreach (string k, _; v)
					if (k != orderKey && !keys.canFind(k))
						rest ~= k;
				rest.sort!((a, b) {
					auto ia = keyOrder.countUntil(a), ib = keyOrder.countUntil(b);
					if (ia < 0) ia = keyOrder.length;
					if (ib < 0) ib = keyOrder.length;
					return ia != ib ? ia < ib : a < b;
				});
				keys ~= rest;
				if (!keys.length) { app.put("{}"); return; }
				app.put("{\n");
				foreach (i, k; keys)
				{
					app.put(pad(indent + 1));
					app.put(Json(k).toString);
					app.put(": ");
					write(v[k], indent + 1);
					app.put(i + 1 < keys.length ? ",\n" : "\n");
				}
				app.put(pad(indent) ~ "}");
				return;
			case Json.Type.array:
				if (!v.length) { app.put("[]"); return; }
				app.put("[\n");
				foreach (size_t i, Json e; v)
				{
					app.put(pad(indent + 1));
					write(e, indent + 1);
					app.put(i + 1 < v.length ? ",\n" : "\n");
				}
				app.put(pad(indent) ~ "]");
				return;
			default:
				app.put(v.toString);
		}
	}
	write(j, 0);
	app.put("\n");
	return app.data;
}

/// The Swagger UI page for `specUrl` (both under `basePath`).
string swaggerPage(string title, string basePath, string specUrl)
{
	import streamlitd.util : htmlEscapeAttr;
	auto t = htmlEscapeAttr(title);
	auto b = htmlEscapeAttr(basePath);
	// JSON-encode for the inline script; escape "</" so the string can't end the <script> element
	auto spec = Json(basePath ~ specUrl).toString.replace("</", `<\/`);
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>` ~ t ~ ` · API docs</title>
<link rel="icon" href="` ~ b ~ `/_stcore/favicon">
<link rel="stylesheet" href="` ~ b ~ `/_stcore/swagger/swagger-ui.css">
<style>body{margin:0}</style>
</head>
<body>
<div id="swagger-ui"></div>
<script src="` ~ b ~ `/_stcore/swagger/swagger-ui-bundle.js"></script>
<script>
window.ui = SwaggerUIBundle({ url: ` ~ spec ~ `, dom_id: "#swagger-ui", deepLinking: true, validatorUrl: null,
  tryItOutEnabled: false, persistAuthorization: false, withCredentials: true });
</script>
</body>
</html>
`;
}

/// Embedded Swagger UI file (`swagger-ui-bundle.js`, `swagger-ui.css`), or null.
string swaggerAsset(string file)
{
	import streamlitd.assetlist : swaggerAssetNames;
	switch ("vendor/swagger-ui/" ~ file)
	{
		static foreach (n; swaggerAssetNames)
		{
			case n: return import(n);
		}
		default: return null;
	}
}

unittest
{
	import std.datetime : Date;
	import std.typecons : Nullable;
	import vibe.data.serialization : name, optional, ignore, byName;

	enum Color { red = 1, green = 2 }
	struct Inner { string label; }
	struct Item
	{
		long id;
		@name("display") string title;
		@optional double price;
		@ignore int secret;
		Inner[] tags;
		int[string] counts;
		Color color;
		@byName Color named;
		Nullable!int maybe;
		Date day;
		bool done;
		string version_;
	}
	ApiRegistry reg0;
	auto r = schemaOf!Item(reg0);
	auto s = reg0.schemas;
	assert(r["$ref"].get!string == "#/components/schemas/Item");
	auto item = s["Item"];
	auto p = item["properties"];
	assert(p["id"]["type"].get!string == "integer" && p["id"]["format"].get!string == "int64");
	assert(p["display"]["type"].get!string == "string" && p["title"].type == Json.Type.undefined);
	assert(p["secret"].type == Json.Type.undefined);
	assert(p["tags"]["items"]["$ref"].get!string == "#/components/schemas/Inner" && "Inner" in s);
	assert(p["counts"]["additionalProperties"]["type"].get!string == "integer");
	assert(p["color"]["enum"] == Json([Json(1), Json(2)]));
	assert(p["named"]["enum"] == Json([Json("red"), Json("green")]));
	assert(p["maybe"]["nullable"].get!bool && p["day"]["format"].get!string == "date");
	assert(p["done"]["type"].get!string == "boolean" && "version" in p);
	import std.algorithm : canFind;
	auto req = item["required"].get!(Json[]);
	assert(req.canFind(Json("id")) && !req.canFind(Json("price")) && !req.canFind(Json("secret")));
	// recursive types terminate
	static class Node { Node[] children; string name; }
	ApiRegistry reg2;
	schemaOf!Node(reg2);
	assert(reg2.schemas["Node"]["properties"]["children"]["items"]["$ref"].get!string == "#/components/schemas/Node");

	assert(openApiPath("/api/todos/:_id") == "/api/todos/{id}");
	assert(openApiPath("/a/:x/b") == "/a/{x}/b");
}

unittest
{
	import std.algorithm : canFind;
	import vibe.web.rest : path, method, viaQuery;

	struct Todo { long id; string title; bool done; }
	@path("/api")
	interface TestApi
	{
	@safe:
		@path("/todos") @method(HTTPMethod.GET) @apiDoc("List todos", "Filter with ?done=")
		Todo[] list(@viaQuery("done") string done = null);
		@path("/todos/:id") @method(HTTPMethod.GET)
		Todo get(long _id);
		@path("/todos") @method(HTTPMethod.POST)
		Todo create(string title, bool done = false);
		@path("/todos/:id") @method(HTTPMethod.DELETE)
		void remove(long _id);
	}
	static class TestImpl : TestApi
	{
	@safe:
		Todo[] list(string done) { return null; }
		Todo get(long id) { return Todo.init; }
		Todo create(string title, bool done) { return Todo.init; }
		void remove(long id) {}
	}

	ApiRegistry reg;
	describeInterface!TestImpl(null, reg);
	assert(reg.operations.length == 4);
	auto routes = [AppRoute(HTTPMethod.GET, "/api/todos"), AppRoute(HTTPMethod.GET, "/api/todos/:_id"),
		AppRoute(HTTPMethod.OPTIONS, "/api/todos"), AppRoute(HTTPMethod.GET, "/api/stats"),
		AppRoute(HTTPMethod.POST, "/hooks/:name"), AppRoute(HTTPMethod.GET, "/files/*")];
	ApiDocsOptions o;
	o.title = "Test";
	auto doc = parseJsonString(buildOpenApiSpec(o, "/sub", routes, true, true, reg));
	assert(doc["openapi"].get!string == "3.0.3" && doc["info"]["title"].get!string == "Test");
	assert(doc["servers"][0]["url"].get!string == "/sub");
	auto list = doc["paths"]["/api/todos"]["get"];
	assert(list["summary"].get!string == "List todos" && list["description"].get!string == "Filter with ?done=");
	assert(list["parameters"][0]["name"].get!string == "done" && list["parameters"][0]["in"].get!string == "query"
		&& !list["parameters"][0]["required"].get!bool);
	assert(list["responses"]["200"]["content"]["application/json"]["schema"]["items"]["$ref"].get!string
		== "#/components/schemas/Todo");
	auto get = doc["paths"]["/api/todos/{id}"]["get"];
	assert(get["parameters"][0]["name"].get!string == "id" && get["parameters"][0]["in"].get!string == "path");
	auto create = doc["paths"]["/api/todos"]["post"];
	auto body_ = create["requestBody"]["content"]["application/json"]["schema"];
	assert(body_["properties"]["title"]["type"].get!string == "string" && body_["required"] == Json([Json("title")]));
	assert("delete" in doc["paths"]["/api/todos/{id}"]);
	assert(doc["paths"]["/api/todos"]["options"].type == Json.Type.undefined);
	// plain handlers: method and path only; wildcards are left out
	assert(doc["paths"]["/api/stats"]["get"]["tags"][0].get!string == "other");
	assert(doc["paths"]["/hooks/{name}"]["post"]["parameters"][0]["in"].get!string == "path");
	assert(doc["paths"]["/files/*"].type == Json.Type.undefined);
	// login
	assert(doc["components"]["securitySchemes"]["streamlitdLogin"]["in"].get!string == "cookie");
	assert(doc["security"][0]["streamlitdLogin"].type == Json.Type.array);
	// operation ids are unique
	string[] ids;
	foreach (string p, ops; doc["paths"])
		foreach (string m, op; ops)
		{
			assert(!ids.canFind(op["operationId"].get!string));
			ids ~= op["operationId"].get!string;
		}
	assert(swaggerPage("A </script>", "/b", "/openapi.json").canFind(`"/b/openapi.json"`));
	assert(!swaggerPage("A </script>", "", "/x").canFind("A </script>"));
	assert(swaggerAsset("swagger-ui.css").length > 1000 && swaggerAsset("nope.js") is null);
}

// review fixes: name collisions, vibe.d serializer details, `any` routes, optional request bodies
unittest
{
	import std.algorithm : canFind;
	import std.typecons : Nullable, Typedef;
	import std.uuid : UUID;
	import vibe.data.serialization : embedNullable;
	import vibe.web.rest : path, method;

	static struct A { struct Item { int a; } }
	static struct B { struct Item { string b; } }
	struct Error { int code; }
	static struct Raw
	{
		int hidden;
		Json toJson() const @safe { return Json(1); }
		static Raw fromJson(Json j) @safe { return Raw.init; }
	}
	struct Misc
	{
		Nullable!(int, -1) sentinel;
		@embedNullable Nullable!int embedded;
		uint big;
		ubyte small;
		UUID uid;
		Typedef!long tid;
		Raw raw;
	}
	ApiRegistry reg;
	assert(schemaOf!(A.Item)(reg)["$ref"].get!string == "#/components/schemas/Item");
	assert(schemaOf!(B.Item)(reg)["$ref"].get!string == "#/components/schemas/Item_2");
	assert(schemaOf!(A.Item)(reg)["$ref"].get!string == "#/components/schemas/Item"); // stable
	assert(reg.schemas["Item_2"]["properties"]["b"]["type"].get!string == "string");
	assert(schemaOf!Error(reg)["$ref"].get!string == "#/components/schemas/Error_2"); // "Error" is streamlitd's
	schemaOf!Misc(reg);
	auto p = reg.schemas["Misc"]["properties"];
	assert(p["sentinel"]["type"].get!string == "integer" && p["sentinel"]["nullable"].get!bool);
	assert(!reg.schemas["Misc"]["required"].get!(Json[]).canFind(Json("embedded")));
	assert(p["big"]["format"].get!string == "int64" && p["big"]["minimum"].get!int == 0);
	assert(p["small"]["format"].get!string == "int32" && p["small"]["minimum"].get!int == 0);
	assert(p["uid"]["format"].get!string == "uuid");
	assert(p["tid"]["type"].get!string == "integer" && p["tid"]["format"].get!string == "int64");
	assert(p["raw"] == Json.emptyObject && "Raw" !in reg.schemas);

	@path("/api")
	interface OptApi
	{
	@safe:
		@path("/things/:id") @method(HTTPMethod.PATCH)
		void update(long _id, string title = null, bool done = false);
	}
	static class OptImpl : OptApi
	{
	@safe:
		void update(long id, string title, bool done) {}
	}
	ApiRegistry reg3;
	describeInterface!OptImpl(null, reg3);
	assert(!reg3.operations[0].op["requestBody"]["required"].get!bool);

	AppRoute[] routes;
	foreach (m; [HTTPMethod.GET, HTTPMethod.POST, HTTPMethod.PROPFIND, HTTPMethod.COPY, HTTPMethod.TRACE])
		routes ~= AppRoute(m, "/hook");
	auto doc = parseJsonString(buildOpenApiSpec(ApiDocsOptions.init, "", routes, false, false, reg3));
	string[] keys;
	foreach (string k, _; doc["paths"]["/hook"])
		keys ~= k;
	assert(keys.length == 3 && keys.canFind("get") && keys.canFind("trace") && !keys.canFind("propfind"), keys.to!string);
	assert(doc["components"]["schemas"]["Error"]["properties"]["statusMessage"].type == Json.Type.object);
}
