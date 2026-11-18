/// HTTP/WebSocket server built on vibe.d.
module streamlitd.server;

import std.conv : to;
import std.stdio : writeln, stderr;
import std.functional : toDelegate;
import std.array : join;

import vibe.core.core;
import core.time : seconds, Duration;
import vibe.core.sync;
import vibe.core.log;
import vibe.data.json;
import vibe.http.router;
import vibe.http.server;
import vibe.http.websockets;
import vibe.stream.operations : readAll;

import streamlitd.media;
import streamlitd.session;
import streamlitd.util;
import streamlitd.theme;
import streamlitd.executor;
import streamlitd.authserver;
import streamlitd.accounts : AccountError;
import streamlitd.delta : UserInfo;
import streamlitd.openapi;
import streamlitd.extensions : registerElement, buildExtensionAssets, ExtensionAssets;

public import streamlitd.config : ServerOptions;
import streamlitd.config;

import streamlitd.assetlist : assetNames;

private string assetContent(string name)
{
	switch (name)
	{
		static foreach (n; assetNames)
		{
			case n: return import(n);
		}
		default: return null;
	}
}

/// Largest accepted client message (bytes).
enum maxClientMessage = 16 * 1024 * 1024;

private AuthConfig g_auth;
// app extensions (custom designs and elements): `_stcore/ext.css`, `_stcore/ext/<element>.js`
private __gshared ExtensionAssets g_ext;

/// Register the color schemes, designs and elements defined in config files, then close the
/// registries and build the extension stylesheet/script. Throws on invalid definitions.
private void setupExtensions(ref ServerOptions opts)
{
	import streamlitd.theme : freezeExtensions;
	foreach (c; opts.schemes)
		registerColorScheme(c.name, c.label, c.both, c.light, c.dark, c.base);
	foreach (d; opts.designs)
		registerDesign(d.style, null, d.cssPath);
	foreach (e; opts.elements)
		registerElement(e.name, null, null, e.jsPath, e.cssPath);
	freezeExtensions();
	g_ext = buildExtensionAssets();
}

private void serveExtension(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.algorithm : endsWith;
	immutable css = req.requestPath.toString.endsWith("/ext.css");
	string content;
	if (css)
		content = g_ext.css;
	else
	{
		auto file = req.params.get("file", "");
		if (file.endsWith(".js"))
			if (auto s = g_ext.script(file[0 .. $ - 3]))
				content = s.js;
	}
	if (!content.length)
	{
		res.statusCode = 404;
		return res.writeBody("not found");
	}
	// the page links them with ?v=<content hash>, so they can be cached for long
	res.headers["Cache-Control"] = req.query.get("v", null) !is null ? "public, max-age=31536000, immutable" : "no-cache";
	res.writeBody(content, css ? "text/css; charset=UTF-8" : "application/javascript; charset=UTF-8");
}

// app-wide favicon from --favicon / [server] favicon (empty = embedded default icons)
private immutable(ubyte)[] g_favicon;
private string g_faviconMime;

/// Load the configured favicon file; throws if it cannot be read.
void loadFavicon(string path, out immutable(ubyte)[] data, out string mime)
{
	import std.file : exists, read, isFile;
	import std.exception : enforce;
	enforce(exists(path) && isFile(path), "favicon file not found: " ~ path);
	data = cast(immutable(ubyte)[]) read(path);
	mime = mimeFromName(path);
	if (mime == "application/octet-stream")
		mime = mimeFromBytes(data);
	enforce(mime.length > 6 && mime[0 .. 6] == "image/", "favicon must be an image (svg, png, ico, jpg, gif, webp): " ~ path);
}

private void serveFavicon(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.algorithm : endsWith;
	res.headers["Cache-Control"] = "public, max-age=86400";
	if (g_favicon.length)
	{
		res.writeBody(g_favicon, g_faviconMime);
		return;
	}
	auto p = req.requestPath.toString();
	string name = p.endsWith(".svg") ? "favicon.svg" : p.endsWith("favicon-32.png") ? "favicon-32.png"
		: p.endsWith("apple-touch-icon.png") ? "apple-touch-icon.png" : "favicon.ico";
	auto mime = name.endsWith(".svg") ? "image/svg+xml" : name.endsWith(".png") ? "image/png" : "image/x-icon";
	res.writeBody(cast(const(ubyte)[]) assetContent(name), mime);
}
private AppFn g_app;
private ServerOptions g_opts;
private AppSession[string] g_sessions;

private final class WSTransport : Transport
{
	WebSocket sock;
	bool closed;

	this(WebSocket s) { sock = s; }

	void send(Json msg)
	{
		if (closed)
			return;
		try
			sock.send(msg.toString());
		catch (Exception e)
			closed = true;
	}
}


unittest
{
	assert(originAllowed("", "h:1", null));
	assert(originAllowed("http://h:1", "h:1", null));
	assert(originAllowed("https://h:1", "h:1", null));
	assert(!originAllowed("http://evil.com", "h:1", null));
	assert(originAllowed("http://evil.com", "h:1", ["http://evil.com"]));
	assert(originAllowed("http://x", "h", ["*"]));
}

private bool checkOrigin(HTTPServerRequest req, HTTPServerResponse res)
{
	if (originAllowed(req.headers.get("Origin", ""), req.host, g_opts.allowedOrigins))
		return true;
	res.statusCode = 403;
	res.writeBody("origin not allowed");
	return false;
}

private HTTPServerRequestDelegateS g_wsHandler;

private void handleWSRequest(HTTPServerRequest req, HTTPServerResponse res)
{
	if (!checkOrigin(req, res))
		return;
	if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
	{
		res.statusCode = 401;
		res.writeBody("login required");
		return;
	}
	if (g_opts.maxSessions > 0 && g_sessions.length >= g_opts.maxSessions)
	{
		res.statusCode = 503;
		res.writeBody("too many sessions");
		return;
	}
	g_wsHandler(req, res);
}

private void handleWS(scope WebSocket sock) @system
{
	immutable threaded = g_opts.scriptThreads != 0;
	WSTransport direct;
	OutboxTransport outbox;
	Transport transport;
	if (threaded)
		transport = outbox = new OutboxTransport;
	else
		transport = direct = new WSTransport(sock);

	auto sess = new AppSession(g_app, transport);
	sess.defaultTheme = g_opts.theme;
	sess.user = userFromRequest(g_auth, cast(HTTPServerRequest) sock.request);
	sess.authEnabled = g_auth.enabled;
	sess.authRequired = g_auth.required;
	sess.mapTileUrl = g_opts.mapTileUrl;
	sess.mapAttribution = g_opts.mapAttribution;
	sess.allowThemeSwitch = g_opts.allowThemeSwitch;
	sess.ui = jo("rerunButton", g_opts.ui.rerunButton, "settingsButton", g_opts.ui.settingsButton,
		"rerunShortcut", g_opts.ui.rerunShortcut);
	g_sessions[sess.id] = sess;
	auto ev = createSharedManualEvent(); // shared: FragmentRef.refresh and refreshFragments may wake it from any thread
	sess.onRerunRequested = () { ev.emit(); };
	sess.yielder = () { yield(); };

	// in threaded mode a writer task forwards queued messages to the socket
	Task writer;
	if (threaded)
	{
		writer = runTask(() nothrow {
			try
			{
				while (true)
				{
					auto c = outbox.event.emitCount;
					auto msgs = outbox.drain();
					foreach (m; msgs)
						sock.send(m);
					if (msgs.length == 0)
					{
						if (outbox.isClosed())
							break;
						outbox.event.wait(c);
					}
				}
			}
			catch (Exception) {}
		});
	}
	sess.send(sess.newSessionMessage());

	auto runner = runTask(() nothrow {
		try
		{
			while (!sess.isClosed())
			{
				if (sess.isRerunRequested())
				{
					if (threaded)
						runOnceInWorker(sess);
					else
						sess.runPending();
				}
				else
				{
					// st.fragment(runEvery: ...) auto-refresh
					string due;
					auto wait = sess.nextFragmentDue(due);
					if (due.length)
					{
						sess.requestRerun(null, null, Json.undefined, due);
						continue;
					}
					auto c = ev.emitCount;
					if (!sess.isRerunRequested() && !sess.isClosed())
					{
						if (wait == Duration.max)
							ev.wait(c);
						else
							ev.wait(wait, c);
					}
				}
			}
		}
		catch (Exception e)
		{
			try stderr.writeln("streamlitd: session runner failed: ", e.msg); catch (Exception) {}
		}
	});

	try
	{
		while (g_opts.idleTimeoutSeconds > 0 ? sock.waitForData(seconds(g_opts.idleTimeoutSeconds)) : sock.waitForData())
		{
			auto txt = sock.receiveText();
			if (txt.length > maxClientMessage)
			{
				stderr.writeln("streamlitd: client message too large, ignored");
				continue;
			}
			try
				sess.handleClientMessage(parseJsonString(txt));
			catch (Exception e)
				stderr.writeln("streamlitd: bad client message: ", e.msg);
		}
	}
	catch (Exception) {}

	sess.close();
	if (direct !is null)
		direct.closed = true;
	ev.emit();
	runner.join();
	if (outbox !is null)
	{
		outbox.close();
		writer.join();
	}
	g_sessions.remove(sess.id);
	MediaManager.releaseSession(sess.id);
}

private void serveAsset(HTTPServerRequest req, HTTPServerResponse res)
{
	auto full = req.requestPath.toString();
	auto prefix = g_opts.baseUrlPath ~ "/static/";
	auto name = full.length > prefix.length ? full[prefix.length .. $] : "";
	auto content = assetContent(name);
	if (content is null)
	{
		res.statusCode = 404;
		res.writeBody("not found");
		return;
	}
	string mime = "application/octet-stream";
	import std.algorithm : endsWith;
	if (name.endsWith(".js")) mime = "application/javascript; charset=UTF-8";
	else if (name.endsWith(".css")) mime = "text/css; charset=UTF-8";
	else if (name.endsWith(".html")) mime = "text/html; charset=UTF-8";
	else if (name.endsWith(".woff2")) mime = "font/woff2";
	else if (name.endsWith(".svg")) mime = "image/svg+xml";
	else if (name.endsWith(".png")) mime = "image/png";
	if (name.length > 7 && name[0 .. 7] == "vendor/")
		res.headers["Cache-Control"] = "public, max-age=86400";
	else
		res.headers["Cache-Control"] = "no-cache";
	res.writeBody(content, mime);
}


private void serveIndex(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.array : replace;
	if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
	{
		res.redirect(loginRedirect(req));
		return;
	}
	res.headers["Cache-Control"] = "no-cache";
	auto html = assetContent("index.html").replace("<head>", `<head>
<base href="` ~ htmlEscapeAttr(g_opts.baseUrlPath) ~ `/">`);
	if (g_favicon.length)
	{
		// one icon link for the custom file (avoid mixing it with the default SVG/PNG pair)
		html = html.replace(`<link rel="icon" type="image/svg+xml" href="_stcore/favicon.svg" data-default-icon>`,
			`<link rel="icon" type="` ~ g_faviconMime ~ `" href="_stcore/favicon" data-default-icon>`)
			.replace(`<link rel="icon" sizes="32x32" type="image/png" href="_stcore/favicon-32.png" data-default-icon>`, "")
			.replace(`<link rel="apple-touch-icon" href="_stcore/apple-touch-icon.png">`, `<link rel="apple-touch-icon" href="_stcore/favicon">`);
	}
	if (g_ext.css.length)
		html = html.replace(`<link rel="stylesheet" href="static/designs.css">`,
			`<link rel="stylesheet" href="static/designs.css">
<link rel="stylesheet" href="_stcore/ext.css?v=` ~ g_ext.cssHash ~ `">`);
	if (g_ext.scripts.length)
	{
		// one file per element: a syntax error in one script does not stop the others
		string tags;
		foreach (s; g_ext.scripts)
			tags ~= "\n<script src=\"_stcore/ext/" ~ s.name ~ ".js?v=" ~ s.hash ~ "\"></script>";
		html = html.replace(`<script src="static/app.js"></script>`, `<script src="static/app.js"></script>` ~ tags);
	}
	res.writeBody(html, "text/html; charset=UTF-8");
}

private void serveComponent(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.algorithm : canFind, startsWith;
	import std.array : split, join;
	import std.file : exists, isFile, read;
	import std.path : buildNormalizedPath, absolutePath;
	import streamlitd.components : findComponent;
	auto full = req.requestPath.toString();
	auto prefix = g_opts.baseUrlPath ~ "/_components/";
	auto rest = full.length > prefix.length ? full[prefix.length .. $] : "";
	auto parts = rest.split("/");
	if (parts.length < 2 || parts[0].length == 0)
	{
		res.statusCode = 404;
		res.writeBody("not found");
		return;
	}
	auto c = findComponent(parts[0]);
	auto file = parts[1 .. $].join("/");
	if (file.length == 0)
		file = "index.html";
	if (c is null || file.canFind(".."))
	{
		res.statusCode = 404;
		res.writeBody("not found");
		return;
	}
	if (c.html.length)
	{
		if (file != "index.html")
		{
			res.statusCode = 404;
			res.writeBody("not found");
			return;
		}
		res.writeBody(c.html, "text/html; charset=UTF-8");
		return;
	}
	auto path = buildNormalizedPath(c.dir, file);
	if (!path.startsWith(c.dir) || !exists(path) || !isFile(path))
	{
		res.statusCode = 404;
		res.writeBody("not found");
		return;
	}
	auto mime = mimeFromName(path);
	import std.algorithm : endsWith;
	if (path.endsWith(".js") || path.endsWith(".mjs")) mime = "application/javascript; charset=UTF-8";
	else if (path.endsWith(".css")) mime = "text/css; charset=UTF-8";
	else if (path.endsWith(".html")) mime = "text/html; charset=UTF-8";
	res.headers["Cache-Control"] = "no-cache";
	res.writeBody(cast(const(ubyte)[]) read(path), mime);
}

private void serveMedia(HTTPServerRequest req, HTTPServerResponse res)
{
	if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
	{
		res.statusCode = 401;
		res.writeBody("login required");
		return;
	}
	auto f = MediaManager.get(req.params["id"]);
	if (f is null)
	{
		res.statusCode = 404;
		res.writeBody("not found");
		return;
	}
	if (f.fileName.length)
		res.headers["Content-Disposition"] = `attachment; filename="` ~ f.fileName ~ `"`;
	res.headers["Cache-Control"] = "private, max-age=3600";
	res.writeBody(f.data, f.mime);
}

private void handleUpload(HTTPServerRequest req, HTTPServerResponse res)
{
	if (!checkOrigin(req, res))
		return;
	auto sid = req.params["sid"];
	auto wid = req.params["wid"];
	if (sid !in g_sessions)
	{
		res.statusCode = 403;
		res.writeBody("unknown session");
		return;
	}
	auto name = req.query.get("name", "upload");
	auto type = req.query.get("type", "");
	if (type.length == 0)
		type = mimeFromName(name);
	auto data = req.bodyReader.readAll(g_opts.maxUploadMB * 1024 * 1024).idup;
	auto u = MediaManager.addUpload(sid, wid, name, type, data);
	res.writeJsonBody(jo("fileId", u.fileId, "name", u.name, "type", u.type, "size", u.size));
}

/// Registers your own HTTP routes (JSON APIs, webhooks, REST interfaces) on the app's server.
/// See `StreamlitMain!(app, routes)` and docs/api-endpoints.md.
alias RoutesFn = void delegate(URLRouter router);

/// Path prefixes that belong to streamlitd and can't be used by your own routes.
immutable string[] reservedRoutePrefixes = ["/_stcore", "/static", "/_media", "/_components", "/_upload", "/auth",
	"/oauth2callback", "/favicon.ico"];

/// The reserved prefix `path` falls under, or null.
private string reservedPrefixOf(string path) @safe pure nothrow
{
	import std.algorithm : startsWith;
	foreach (p; reservedRoutePrefixes)
		if (path == p || path.startsWith(p ~ "/"))
			return p;
	return null;
}

/// Normalize and check `[api] docsPath` / `specPath` (from any source: config, env, CLI or code).
package void checkApiDocsPaths(ref ApiDocsOptions a)
{
	a.docsPath = routePath(a.docsPath);
	a.specPath = routePath(a.specPath);
	if (a.docsPath == a.specPath)
		throw new Exception("[api] docsPath and specPath must differ");
	foreach (path; [a.docsPath, a.specPath])
		if (auto p = reservedPrefixOf(path))
			throw new Exception("[api] path " ~ path ~ " is under the reserved prefix " ~ p);
}

/// Throws if `pattern` (a route registered by the app) collides with streamlitd's own routes.
/// `extra` adds exact reserved paths (the API docs paths when they are served).
void checkUserRoute(string pattern, const string[] extra = null)
{
	import std.algorithm : startsWith, canFind;
	if (extra.canFind(pattern))
		throw new Exception("route " ~ pattern ~ " is used by the API docs ([api] docsPath / specPath)");
	if (auto p = reservedPrefixOf(pattern))
		throw new Exception("route " ~ pattern ~ " uses the reserved prefix " ~ p ~
			"; reserved: " ~ reservedRoutePrefixes.join(", "));
	if (pattern == "*" || pattern == "/*")
		throw new Exception("route " ~ pattern ~ " would hide the app page; mount your API under a prefix such as /api/");
}

/// The logged-in streamlitd user for an API request (not logged in when auth is off).
/// Usable as a vibe.d REST `@before!apiUser("user")` filter.
UserInfo apiUser(HTTPServerRequest req, HTTPServerResponse res) @trusted
{
	import streamlitd.delta : makeUserInfo;
	return makeUserInfo(userFromRequest(g_auth, req));
}

/// Like `apiUser`, but answers 401 when nobody is logged in.
/// Usable as a vibe.d REST `@before!requireUser("user")` filter.
UserInfo requireUser(HTTPServerRequest req, HTTPServerResponse res) @trusted
{
	import vibe.http.common : HTTPStatusException;
	auto u = apiUser(req, res);
	if (!u.isLoggedIn)
		throw new HTTPStatusException(401, "login required");
	return u;
}

/// Like `requireUser`, but also answers 403 unless the user has `role` (e.g. "admin").
/// ---
/// r.delete_("/api/items/:id", (req, res) { requireRole(req, res, "editor"); ... });
/// ---
UserInfo requireRole(HTTPServerRequest req, HTTPServerResponse res, string role) @trusted
{
	import vibe.http.common : HTTPStatusException;
	auto u = requireUser(req, res);
	if (!u.hasRole(role))
		throw new HTTPStatusException(403, "the " ~ role ~ " role is required");
	return u;
}

/// Copies the app's routes onto `main`. With `[auth] required`, they answer 401 to anonymous requests.
/// Returns the mounted routes (for the OpenAPI document).
private AppRoute[] mountUserRoutes(URLRouter main, RoutesFn routes, const string[] reserved = null)
{
	static if (apiDocsCompiledIn)
		resetApiRegistry(); // registerApi records into it while `routes` runs
	auto r = new URLRouter;
	routes(r);
	AppRoute[] mounted;
	foreach (rt; r.getAllRoutes())
	{
		checkUserRoute(rt.pattern, reserved);
		main.match(rt.method, rt.pattern, guardedRoute(rt.cb));
		mounted ~= AppRoute(rt.method, rt.pattern);
	}
	return mounted;
}

/// Serve the OpenAPI document, Swagger UI and its files (when `[api] docs` is on and compiled in).
private void registerApiDocs(URLRouter router, string spec)
{
	static if (apiDocsCompiledIn)
	{
		router.get(g_opts.api.specPath, guardedRoute((HTTPServerRequest req, HTTPServerResponse res) @safe {
			res.headers["Cache-Control"] = "no-cache";
			res.writeBody(spec, "application/json; charset=UTF-8");
		}));
		router.get(g_opts.api.docsPath, (HTTPServerRequest req, HTTPServerResponse res) @trusted {
			if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
				return res.redirect(loginRedirect(req));
			res.headers["Cache-Control"] = "no-cache";
			res.writeBody(swaggerPage(g_opts.api.title, g_opts.baseUrlPath, g_opts.api.specPath), "text/html; charset=UTF-8");
		});
		router.get("/_stcore/swagger/:file", (HTTPServerRequest req, HTTPServerResponse res) @trusted {
			import std.algorithm : endsWith;
			auto file = req.params["file"];
			auto content = swaggerAsset(file);
			if (content is null)
			{
				res.statusCode = 404;
				return res.writeBody("not found");
			}
			res.headers["Cache-Control"] = "public, max-age=86400";
			res.writeBody(content, file.endsWith(".css") ? "text/css; charset=UTF-8" : "application/javascript; charset=UTF-8");
		});
	}
}

private void writeApiError(HTTPServerResponse res, int status, string msg) @safe
{
	res.headers["Cache-Control"] = "no-store";
	res.writeJsonBody(Json(["statusMessage": Json(msg)]), status);
}

/// Wraps an app route:
/// - CORS preflights (OPTIONS) pass, since browsers never send cookies with them;
/// - state-changing requests that carry the login cookie must come from an allowed Origin
///   (same check as WebSocket and uploads; requests without an Origin header pass);
/// - with `[auth] required`, anonymous requests get 401;
/// - an `HTTPStatusException` from the handler becomes `{"statusMessage": ...}` like REST errors.
private HTTPServerRequestDelegate guardedRoute(HTTPServerRequestDelegate cb)
{
	return (HTTPServerRequest req, HTTPServerResponse res) @trusted {
		import vibe.http.common : HTTPStatusException;
		if (req.method != HTTPMethod.OPTIONS)
		{
			immutable safeMethod = req.method == HTTPMethod.GET || req.method == HTTPMethod.HEAD;
			if (!safeMethod && req.cookies.get(authCookie, null) !is null
				&& !originAllowed(req.headers.get("Origin", ""), req.host, g_opts.allowedOrigins))
				return writeApiError(res, 403, "origin not allowed");
			if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
				return writeApiError(res, 401, "login required");
		}
		try
			cb(req, res);
		catch (HTTPStatusException e)
		{
			if (res.headerWritten)
				throw e;
			writeApiError(res, e.status, e.msg);
		}
	};
}

/// Start serving `app` and run the event loop (blocks).
/// `routes` adds your own HTTP routes (e.g. a JSON API) under the same port and base path.
int serve(AppFn app, ServerOptions opts = ServerOptions.init, RoutesFn routes = null)
{
	g_app = app;
	opts.baseUrlPath = normalizeBasePath(opts.baseUrlPath);
	g_opts = opts;
	g_wsHandler = handleWebSockets(&handleWS);
	if (opts.favicon.length)
	{
		try
			loadFavicon(opts.favicon, g_favicon, g_faviconMime);
		catch (Exception e)
		{
			stderr.writeln("streamlitd: ", e.msg);
			return 1;
		}
	}
	{
		import streamlitd.secrets : secrets;
		try
		{
			auto cfgAuth = opts.auth.type == Json.Type.object ? opts.auth.clone : Json.emptyObject;
			if (opts.authRequired)
				cfgAuth["required"] = true;
			import streamlitd.secrets : deepMerge;
			auto secAuth = secrets().get!Json("auth");
			if (opts.authEnv.type == Json.Type.object) // env wins over both files
				secAuth = deepMerge(secAuth.type == Json.Type.object ? secAuth : Json.emptyObject, opts.authEnv);
			g_auth = loadAuthConfig(cfgAuth, secAuth, opts.baseUrlPath);
			g_auth.trustProxy = opts.trustProxy;
			g_auth.allowedOrigins = opts.allowedOrigins;
			import streamlitd.accounts : setAccounts;
			setAccounts(g_auth.enabled ? g_auth.accounts : null);
		}
		catch (Exception e)
		{
			stderr.writeln("streamlitd: auth configuration error: ", e.msg);
			return 1;
		}
	}
	try
		setupExtensions(opts);
	catch (Exception e)
	{
		stderr.writeln("streamlitd: ", e.msg);
		return 1;
	}
	// after setupExtensions: the app's scheme may come from [theme.schemes.*]
	g_auth.pageColors = authPageColors(opts.theme);
	if (opts.scriptThreads != 0)
		startScriptWorkers(opts.scriptThreads < 0 ? 0 : cast(uint) opts.scriptThreads);

	auto router = new URLRouter(opts.baseUrlPath);
	router.get("/_stcore/health", (HTTPServerRequest req, HTTPServerResponse res) { res.writeBody("ok"); });
	foreach (f; ["/_stcore/favicon", "/_stcore/favicon.svg", "/_stcore/favicon-32.png", "/_stcore/apple-touch-icon.png", "/favicon.ico"])
		router.get(f, &serveFavicon);
	router.get("/_stcore/ws", &handleWSRequest);
	router.get("/_stcore/ext.css", &serveExtension);
	router.get("/_stcore/ext/:file", &serveExtension);
	router.get("/static/*", &serveAsset);
	router.get("/_media/:id", &serveMedia);
	router.get("/_components/*", &serveComponent);
	router.post("/_upload/:sid/:wid", &handleUpload);
	if (g_auth.enabled)
		registerAuthRoutes(router, &g_auth);
	immutable apiDocs = opts.api.docs && apiDocsCompiledIn;
	if (opts.api.docs && !apiDocsCompiledIn)
		stderr.writeln("streamlitd: [api] docs is on, but the API docs were compiled out (dub version StreamlitdNoApiDocs)");
	AppRoute[] appRoutes;
	try
	{
		if (apiDocs)
		{
			checkApiDocsPaths(opts.api);
			g_opts.api = opts.api;
		}
		if (routes !is null)
			appRoutes = mountUserRoutes(router, routes, apiDocs ? [opts.api.docsPath, opts.api.specPath] : null);
		static if (apiDocsCompiledIn)
			if (apiDocs)
				registerApiDocs(router, buildOpenApiSpec(opts.api, opts.baseUrlPath, appRoutes, g_auth.enabled, g_auth.required));
	}
	catch (Exception e)
	{
		stderr.writeln("streamlitd: ", e.msg);
		return 1;
	}
	router.get("*", &serveIndex);

	auto settings = new HTTPServerSettings;
	settings.port = opts.port;
	settings.bindAddresses = [opts.host];
	settings.maxRequestSize = opts.maxUploadMB * 1024 * 1024 + 4096;
	settings.webSocketPingInterval = seconds(20);
	settings.accessLogger = null;
	// browsers ask for /favicon.ico at the server root even when the app lives under a base path
	HTTPServerRequestHandler handler = router;
	if (opts.baseUrlPath.length)
	{
		auto outer = new URLRouter;
		outer.get("/favicon.ico", &serveFavicon);
		outer.any("*", router);
		handler = outer;
	}
	auto listener = listenHTTP(settings, handler);
	scope (exit) listener.stopListening();

	if (!opts.quiet)
	{
		writeln();
		writeln("  You can now view your streamlitd app in your browser.");
		writeln();
		writeln("  Local URL: http://localhost:", opts.port, opts.baseUrlPath, "/");
		if (apiDocs)
			writeln("  API docs:  http://localhost:", opts.port, opts.baseUrlPath, opts.api.docsPath,
				"  (OpenAPI: ", opts.baseUrlPath, opts.api.specPath, ")");
		if (opts.host == "0.0.0.0" || opts.host == "::")
			writeln("  Listening on all network interfaces, port ", opts.port);
		else if (opts.host != "127.0.0.1" && opts.host != "localhost")
			writeln("  Network URL: http://", opts.host, ":", opts.port);
		writeln();
	}
	string[] unrecognized; // our own options were already parsed by runMain
	return runApplication(&unrecognized);
}

/// Extract `--theme.<key>=<value>` arguments into `overrides`; returns the remaining args.
string[] parseThemeOverrides(string[] args, ref ThemeTokens overrides)
{
	import std.algorithm : startsWith, countUntil;
	string[] rest;
	foreach (a; args)
	{
		if (a.startsWith("--theme."))
		{
			auto kv = a["--theme.".length .. $];
			auto eq = kv.countUntil('=');
			auto key = eq < 0 ? kv : kv[0 .. eq];
			auto value = eq < 0 ? null : kv[eq + 1 .. $];
			if (key == "font" || key == "headingFont" || key == "codeFont")
				value = streamlitFont(value); // Streamlit keywords: "sans serif", "serif", "monospace"
			if (eq < 0 || !overrides.set(key, value))
				throw new Exception("Bad theme option '" ~ a ~ "'. Use --theme.<key>=<value>, e.g. --theme.primaryColor=#ff0000");
		}
		else
			rest ~= a;
	}
	return rest;
}

unittest
{
	ThemeTokens t;
	auto rest = parseThemeOverrides(["app", "--theme.primaryColor=#123456", "--port", "1", "--theme.font=serif"], t);
	assert(rest == ["app", "--port", "1"]);
	assert(t.primaryColor == "#123456" && t.font == fontSerif);
	import std.exception : assertThrown;
	assertThrown(parseThemeOverrides(["--theme.nope=1"], t));
}

/// Run a user command (`--add-user`, `--list-users`, ...) on the configured user store.
private int runUserCommand(ServerOptions o)
{
	import streamlitd.accounts : AccountError;
	import streamlitd.secrets : secrets, deepMerge;
	import std.stdio : writefln;
	auto cmd = o.userCommand;
	AuthConfig c;
	try
	{
		auto secAuth = secrets().get!Json("auth");
		if (o.authEnv.type == Json.Type.object)
			secAuth = deepMerge(secAuth.type == Json.Type.object ? secAuth : Json.emptyObject, o.authEnv);
		c = loadAuthConfig(o.auth.type == Json.Type.object ? o.auth.clone : Json.emptyObject, secAuth, o.baseUrlPath);
	}
	catch (Exception e)
	{
		stderr.writeln("streamlitd: auth configuration error: ", e.msg);
		return 1;
	}
	if (!c.configured)
	{
		stderr.writeln("streamlitd: authentication is not configured. Add an [auth] section to .streamlitd/config.toml, e.g.\n",
			"  [auth]\n  registration = \"first_admin\"   # or \"off\" to create every user with --add-user");
		return 1;
	}
	auto acc = c.accounts;
	try
	{
		switch (cmd.kind)
		{
			case "add":
				auto pw = readNewPassword("Password for " ~ cmd.username);
				auto u = acc.createUser(cmd.username, pw, cmd.name, cmd.email, cmd.roles);
				writeln("created user ", u.username, u.roles.length ? " (roles: " ~ u.roles.join(", ") ~ ")" : "");
				break;
			case "set-password":
				acc.setPassword(cmd.username, readNewPassword("New password for " ~ cmd.username));
				writeln("password changed; existing logins of ", cmd.username, " ended");
				break;
			case "set-roles":
				acc.setRoles(cmd.username, cmd.roles);
				writeln("roles of ", cmd.username, ": ", cmd.roles.length ? cmd.roles.join(", ") : "(none)");
				break;
			case "delete":
				acc.deleteUser(cmd.username);
				writeln("deleted user ", cmd.username);
				break;
			case "reset-link":
				writeln(acc.createResetLink(cmd.username));
				stderr.writeln("(valid 24 hours, once; put your server's address in front of it)");
				break;
			case "list":
				auto users = acc.users;
				if (!users.length)
					writeln("no users in the user store");
				foreach (u; users)
					writefln("%-24s %-20s %-28s %-16s %s%s", u.username, u.name, u.email, u.roles.join(","), u.status,
						u.provider.length ? " (" ~ u.provider ~ ")" : "");
				break;
			default:
				assert(0);
		}
	}
	catch (AccountError e)
	{
		stderr.writeln("streamlitd: ", e.msg);
		return 1;
	}
	return 0;
}

/// Ask for a new password twice without echo on a terminal; read one line from a pipe.
private string readNewPassword(string prompt)
{
	import std.stdio : stdin, readln, write;
	import std.string : chomp;
	version (Posix)
	{
		import core.sys.posix.unistd : isatty;
		import core.sys.posix.termios;
		if (isatty(0))
		{
			string ask(string p)
			{
				stderr.write(p, ": ");
				termios old, quiet;
				tcgetattr(0, &old);
				quiet = old;
				quiet.c_lflag &= ~ECHO;
				tcsetattr(0, TCSANOW, &quiet);
				scope (exit) { tcsetattr(0, TCSANOW, &old); stderr.writeln(); }
				return readln().chomp;
			}
			auto a = ask(prompt);
			if (ask("Repeat it") != a)
				throw new AccountError("The passwords do not match.");
			return a;
		}
	}
	return readln().chomp;
}

/// The login page, returning to the requested page afterwards.
private string loginRedirect(HTTPServerRequest req)
{
	import std.uri : encodeComponent;
	auto target = req.requestURI;
	return g_opts.baseUrlPath ~ "/auth/login" ~ (target.length > 1 && target != g_opts.baseUrlPath ~ "/"
		? "?next=" ~ encodeComponent(target) : "");
}

/// Primary color and text on it (light, dark) of the app's color scheme, for the login pages.
package string[4] authPageColors(const Theme t)
{
	auto p = findPreset(t.scheme);
	if (p is null)
		return ["#ff4b4b", "#ffffff", "#ff4b4b", "#ffffff"];
	auto l = p.light.merged(t.overrides), d = p.dark.merged(t.overrides);
	string or(string a, string b) { return a.length ? a : b; }
	auto lt = or(l.primaryTextColor, "#ffffff"), dt = or(d.primaryTextColor, "#ffffff");
	return [readablePrimary(or(l.primaryColor, "#ff4b4b"), lt), lt, readablePrimary(or(d.primaryColor, "#ff4b4b"), dt), dt];
}

/// The primary color darkened (or lightened, for dark text) until `onPrimary` text on it reaches
/// 4.5:1, like the app's `--primary-strong`.
package string readablePrimary(string primary, string onPrimary)
{
	import std.format : format;
	import std.math : pow;
	double[3] rgb(string h)
	{
		if (h.length == 4)
			h = "#" ~ h[1] ~ h[1] ~ h[2] ~ h[2] ~ h[3] ~ h[3];
		if (h.length != 7)
			return [0, 0, 0];
		return [h[1 .. 3].to!int(16), h[3 .. 5].to!int(16), h[5 .. 7].to!int(16)];
	}
	double lum(double[3] c)
	{
		double f(double v) { v /= 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
		return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
	}
	double ratio(double[3] a, double[3] b)
	{
		auto x = lum(a), y = lum(b);
		return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
	}
	try
	{
		auto c = rgb(primary), t = rgb(onPrimary);
		immutable towards = lum(t) > 0.5 ? 0.0 : 255.0; // light text: darken; dark text: lighten
		foreach (_; 0 .. 40)
		{
			if (ratio(c, t) >= 4.5)
				break;
			foreach (ref v; c)
				v = v + (towards - v) * 0.06;
		}
		return format("#%02x%02x%02x", cast(int) c[0], cast(int) c[1], cast(int) c[2]);
	}
	catch (Exception)
		return primary;
}

unittest
{
	assert(readablePrimary("#ff4b4b", "#ffffff") != "#ff4b4b"); // 3.6:1 → darker
	assert(readablePrimary("#0055aa", "#ffffff") == "#0055aa");  // already fine
}

/// What `runMain` should do after parsing the command line.
enum ArgsAction { serve, help, hashPassword, userCommand }

/// Build the server options from config files, `STREAMLITD_*` environment variables and the
/// command line (precedence: CLI > env > config file > defaults). Throws on invalid input.
/// `helpText` is filled when `--help` was given.
ServerOptions parseServerArgs(string[] args, string[string] env, out ArgsAction action, out string helpText,
	bool readConfigFiles = true)
{
	import std.getopt;
	import std.algorithm : map;
	import std.array : appender, array;
	ServerOptions o;
	// --config <file> must be known before the file is read
	string configPath;
	foreach (i, a; args)
	{
		if (a == "--config" && i + 1 < args.length)
			configPath = args[i + 1];
		else if (a.length > 9 && a[0 .. 9] == "--config=")
			configPath = a[9 .. $];
	}
	if (readConfigFiles || configPath.length)
		foreach (w; applyConfig(o, loadConfigFiles(configPath)))
			stderr.writeln("streamlitd: config: ", w);
	applyEnv(o, env);

	args = parseThemeOverrides(args, o.theme.overrides);
	// schemes and designs from config files count too (they are registered when the server starts)
	auto schemeNames = colorSchemeNames() ~ o.schemes.map!(c => c.name).array;
	auto designNamesAll = designNames() ~ o.designs.map!(d => d.style.name).array;
	bool noSwitch, hashPassword, listUsers, noRerunShortcut;
	string rerunButton, settingsButton;
	string addUser, setPassword, deleteUser, resetLink, setRoles, roles;
	string unusedConfig;
	auto help = getopt(args, config.passThrough,
		"config", "Config file (default: .streamlitd/config.toml or .streamlit/config.toml)", &unusedConfig,
		"port|p", "Port to listen on (default 8501)", &o.port,
		"host", "Address to bind (default 0.0.0.0)", &o.host,
		"base-url-path", "Serve under a path prefix, e.g. /myapp", &o.baseUrlPath,
		"allowed-origin", "Extra allowed Origin for WebSocket/uploads (repeatable, * = any)", &o.allowedOrigins,
		"max-sessions", "Maximum concurrent sessions (0 = unlimited)", &o.maxSessions,
		"idle-timeout", "Close sessions idle for N seconds (0 = never)", &o.idleTimeoutSeconds,
		"max-upload-mb", "Maximum upload size in MB (default 200)", &o.maxUploadMB,
		"script-threads", "Worker threads for app scripts (-1 = CPU cores, 0 = single-threaded)", &o.scriptThreads,
		"color-scheme", "Color scheme: " ~ schemeNames.join(", "), &o.theme.scheme,
		"theme", "Old name of --color-scheme", &o.theme.scheme,
		"design", "Design style: " ~ designNamesAll.join(", "), &o.theme.design,
		"theme-mode", "auto | light | dark", &o.theme.mode,
		"no-theme-switch", "Hide the viewer's appearance menu", &noSwitch,
		"rerun-button", "Where the rerun button goes: header (default), menu (one ⋮ menu) or hidden", &rerunButton,
		"settings-button", "Where the appearance button goes: header (default), menu or hidden", &settingsButton,
		"no-rerun-shortcut", "The R key does not rerun the app", &noRerunShortcut,
		"hash-password", "Read a password from stdin and print its hash for secrets.toml", &hashPassword,
		"add-user", "Create a user in the user store (asks for the password; see --roles, --email, --name)", &addUser,
		"set-password", "Set a user's password (asks for it)", &setPassword,
		"set-roles", "Set a user's roles (with --roles)", &setRoles,
		"delete-user", "Delete a user from the user store", &deleteUser,
		"list-users", "List the users in the user store", &listUsers,
		"reset-link", "Print a one-time link that lets a user set a new password", &resetLink,
		"roles", "Roles for --add-user / --set-roles, comma-separated (e.g. admin,editor)", &roles,
		"email", "Email for --add-user", &o.userCommand.email,
		"name", "Full name for --add-user", &o.userCommand.name,
		"auth-required", "Require login for the whole app ([auth] must be configured)", &o.authRequired,
		"favicon", "Favicon image file (svg, png, ico, ...) for every page", &o.favicon,
		"api-docs", "Serve the OpenAPI document and Swagger UI for the app's API (--api-docs=false turns it off)", &o.api.docs,
		"quiet|q", "Do not print the startup banner", &o.quiet);
	if (help.helpWanted)
	{
		auto text = appender!string;
		defaultGetoptFormatter(text, "streamlitd app (theme overrides: --theme.<key>=<value>, e.g. --theme.primaryColor=#123456)",
			help.options);
		helpText = text.data;
		action = ArgsAction.help;
		return o;
	}
	action = hashPassword ? ArgsAction.hashPassword : ArgsAction.serve;
	{
		import std.algorithm : splitter, filter;
		import std.string : strip;
		size_t n;
		void cmd(string kind, string user) { if (user.length || (kind == "list" && listUsers)) { o.userCommand.kind = kind; o.userCommand.username = user; n++; } }
		cmd("add", addUser);
		cmd("set-password", setPassword);
		cmd("set-roles", setRoles);
		cmd("delete", deleteUser);
		cmd("list", null);
		cmd("reset-link", resetLink);
		if (n > 1)
			throw new Exception("give only one of --add-user, --set-password, --set-roles, --delete-user, --list-users, --reset-link");
		o.userCommand.rolesGiven = roles !is null;
		foreach (r; roles.splitter(","))
			if (r.strip.length)
				o.userCommand.roles ~= r.strip;
		if (o.userCommand.kind == "set-roles" && !o.userCommand.rolesGiven)
			throw new Exception("--set-roles needs --roles (e.g. --roles admin,editor; --roles= removes all)");
		if (n)
			action = ArgsAction.userCommand;
	}
	if (noSwitch)
		o.allowThemeSwitch = false;
	if (rerunButton !is null)
		o.ui.rerunButton = uiPlacement(rerunButton, "--rerun-button");
	if (settingsButton !is null)
		o.ui.settingsButton = uiPlacement(settingsButton, "--settings-button");
	if (noRerunShortcut)
		o.ui.rerunShortcut = false;
	if (o.favicon.length && action == ArgsAction.serve)
	{
		immutable(ubyte)[] data;
		string mime;
		loadFavicon(o.favicon, data, mime); // fail at startup, not on the first request
	}
	// schemes and designs from config files are registered when the server starts
	validateTheme(o.theme, schemeNames, designNamesAll);
	return o;
}

unittest
{
	import std.exception : assertThrown;
	import std.algorithm : canFind;
	ArgsAction act;
	string helpText;
	auto o = parseServerArgs(["app", "--design", "xp", "--color-scheme", "ocean", "--theme-mode", "dark", "-p", "9001"],
		null, act, helpText, false);
	assert(act == ArgsAction.serve && o.theme.design == "xp" && o.theme.scheme == "ocean" && o.theme.mode == "dark" && o.port == 9001);
	o = parseServerArgs(["app", "--theme", "paper", "--no-theme-switch"], null, act, helpText, false); // old alias
	assert(o.theme.scheme == "paper" && !o.allowThemeSwitch);
	o = parseServerArgs(["app"], ["STREAMLITD_THEME_DESIGN": "retro"], act, helpText, false);
	assert(o.theme.design == "retro");
	o = parseServerArgs(["app", "--design", "glass"], ["STREAMLITD_THEME_DESIGN": "retro"], act, helpText, false); // CLI > env
	assert(o.theme.design == "glass");
	assertThrown(parseServerArgs(["app", "--design", "nope"], null, act, helpText, false));
	assertThrown(parseServerArgs(["app", "--color-scheme", "nope"], null, act, helpText, false));
	// --favicon must point to a readable image
	import std.file : tempDir, write, remove;
	import std.path : buildPath;
	auto ico = buildPath(tempDir, "streamlitd-test-icon.svg");
	write(ico, `<svg xmlns="http://www.w3.org/2000/svg"/>`);
	scope (exit) remove(ico);
	o = parseServerArgs(["app", "--favicon", ico], null, act, helpText, false);
	assert(o.favicon == ico);
	assertThrown(parseServerArgs(["app", "--favicon", ico ~ ".missing"], null, act, helpText, false));
	immutable(ubyte)[] data;
	string mime;
	loadFavicon(ico, data, mime);
	assert(mime == "image/svg+xml" && data.length > 10);
	parseServerArgs(["app", "--help"], null, act, helpText, false);
	assert(act == ArgsAction.help && helpText.canFind("--design") && helpText.canFind("terminal"));
	// API docs: off by default; env and CLI (CLI wins)
	assert(!parseServerArgs(["app"], null, act, helpText, false).api.docs);
	assert(parseServerArgs(["app", "--api-docs"], null, act, helpText, false).api.docs);
	assert(parseServerArgs(["app"], ["STREAMLITD_API_DOCS": "true"], act, helpText, false).api.docs);
	assert(!parseServerArgs(["app", "--api-docs=false"], ["STREAMLITD_API_DOCS": "true"], act, helpText, false).api.docs);
	parseServerArgs(["app", "--help"], null, act, helpText, false);
	assert(helpText.canFind("--api-docs"));
	// schemes and designs defined in the config file: listed in --help and accepted as defaults
	{
		import std.file : write, remove, tempDir;
		import std.path : buildPath;
		auto cfg = buildPath(tempDir, "streamlitd-help-test.toml");
		write(cfg, "[theme]\nscheme = \"dusk\"\n[theme.schemes.dusk]\nprimaryColor = \"#7c3aed\"\n[theme.designs.neon]\nlabel = \"Neon\"\n");
		scope (exit) remove(cfg);
		auto oc = parseServerArgs(["app", "--config", cfg, "--help"], null, act, helpText, false);
		assert(oc.theme.scheme == "dusk" && helpText.canFind("dusk") && helpText.canFind("neon"), helpText);
		assert(parseServerArgs(["app", "--config", cfg, "--design", "neon"], null, act, helpText, false).theme.design == "neon");
	}
}

/// Parse configuration (config.toml, `STREAMLITD_*` env vars, command line) and serve.
/// Precedence: CLI > env > config file > defaults.
int runMain(AppFn app, string[] args, RoutesFn routes = null)
{
	import std.process : environment;
	ServerOptions o;
	try
	{
		ArgsAction action;
		string helpText;
		o = parseServerArgs(args, environment.toAA(), action, helpText);
		final switch (action)
		{
			case ArgsAction.help:
				import std.stdio : write;
				write(helpText);
				return 0;
			case ArgsAction.hashPassword:
				import std.stdio : readln;
				import std.string : chomp;
				import streamlitd.auth : hashPasswordString;
				writeln(hashPasswordString(readln().chomp));
				return 0;
			case ArgsAction.userCommand:
				return runUserCommand(o);
			case ArgsAction.serve:
				break;
		}
	}
	catch (Exception e)
	{
		stderr.writeln("streamlitd: ", e.msg);
		return 1;
	}
	setLogLevel(LogLevel.warn);
	return serve(app, o, routes);
}

unittest
{
	import std.exception : assertThrown, assertNotThrown;
	assertThrown(checkUserRoute("/_stcore/x"));
	assertThrown(checkUserRoute("/static/app.js"));
	assertThrown(checkUserRoute("/auth/login"));
	assertThrown(checkUserRoute("/oauth2callback"));
	assertThrown(checkUserRoute("/favicon.ico"));
	assertThrown(checkUserRoute("*"));
	assertThrown(checkUserRoute("/docs", ["/docs", "/openapi.json"]));
	// [api] docsPath / specPath: normalized, distinct, not under reserved prefixes
	ApiDocsOptions a;
	a.docsPath = "docs";
	checkApiDocsPaths(a);
	assert(a.docsPath == "/docs" && a.specPath == "/openapi.json");
	foreach (bad; ["/static/x", "/_stcore/swagger/x", "/auth", "/openapi.json", "/d/*", "/d/:x", ""])
	{
		ApiDocsOptions b;
		b.docsPath = bad;
		assertThrown(checkApiDocsPaths(b), bad);
	}
	assertNotThrown(checkUserRoute("/docs"));
	assertNotThrown(checkUserRoute("/api/todos/:id"));
	assertNotThrown(checkUserRoute("/staticfiles"));
	assertNotThrown(checkUserRoute("/webhook"));
}

// app routes: mounting, the login/origin guard and JSON errors
unittest
{
	import std.algorithm : canFind;
	import std.exception : assertThrown;
	import vibe.inet.url : URL;
	import vibe.http.common : HTTPStatusException;
	import vibe.stream.memory : createMemoryOutputStream;
	import streamlitd.auth : signValue;

	auto savedAuth = g_auth, savedOpts = g_opts;
	scope (exit) { g_auth = savedAuth; g_opts = savedOpts; }
	g_opts = ServerOptions.init;
	g_auth = loadAuthConfig(parseJsonString(`{"required":true}`), parseJsonString(`{"cookie_secret":"0123456789abcdef!",
		"users":{"ann":{"password_hash":"x","name":"Ann"}}}`), "");

	int calls;
	auto main = new URLRouter;
	mountUserRoutes(main, (URLRouter r) {
		r.get("/api/a", (HTTPServerRequest req, HTTPServerResponse res) { calls++; res.writeBody("ok"); });
		r.post("/api/a", (HTTPServerRequest req, HTTPServerResponse res) { calls++; res.writeBody("posted"); });
		r.match(HTTPMethod.OPTIONS, "/api/a", (HTTPServerRequest req, HTTPServerResponse res) { calls++; res.writeBody("pre"); });
		r.get("/api/fail", (HTTPServerRequest req, HTTPServerResponse res) { throw new HTTPStatusException(418, "teapot"); });
	});
	auto cookie = "streamlitd_auth=" ~ signValue(`{"sub":"ann","name":"Ann","exp":9999999999}`, g_auth.cookieSecret);
	string call(HTTPMethod m, string path, string[string] headers = null)
	{
		import vibe.inet.message : InetHeaderMap;
		InetHeaderMap h;
		h["Host"] = "127.0.0.1:8501";
		foreach (k, v; headers)
			h[k] = v;
		auto sink = createMemoryOutputStream();
		auto req = createTestHTTPServerRequest(URL("http://127.0.0.1:8501" ~ path), m, h);
		auto res = createTestHTTPServerResponse(sink);
		main.handleRequest(req, res);
		res.finalize();
		return cast(string) sink.data.idup;
	}

	// anonymous: 401 JSON; the preflight still reaches the handler
	auto r = call(HTTPMethod.GET, "/api/a");
	assert(r.canFind("401") && r.canFind(`"statusMessage":"login required"`) && calls == 0, r);
	assert(call(HTTPMethod.OPTIONS, "/api/a").canFind("pre") && calls == 1);
	// logged in: allowed; handler exceptions become JSON
	assert(call(HTTPMethod.GET, "/api/a", ["Cookie": cookie]).canFind("ok") && calls == 2);
	r = call(HTTPMethod.GET, "/api/fail", ["Cookie": cookie]);
	assert(r.canFind("418") && r.canFind(`"statusMessage":"teapot"`), r);
	// state-changing requests with the cookie: same origin or no Origin pass, other origins get 403
	assert(call(HTTPMethod.POST, "/api/a", ["Cookie": cookie, "Origin": "http://127.0.0.1:8501"]).canFind("posted"));
	assert(call(HTTPMethod.POST, "/api/a", ["Cookie": cookie]).canFind("posted"));
	r = call(HTTPMethod.POST, "/api/a", ["Cookie": cookie, "Origin": "http://evil.example"]);
	assert(r.canFind("403") && calls == 4, r);
	g_opts.allowedOrigins = ["http://evil.example"];
	assert(call(HTTPMethod.POST, "/api/a", ["Cookie": cookie, "Origin": "http://evil.example"]).canFind("posted"));

	assertThrown(mountUserRoutes(new URLRouter, (URLRouter r) {
		r.get("/oauth2callback", (HTTPServerRequest req, HTTPServerResponse res) {});
	}));
}

unittest
{
	// the login pages use the app's scheme, also one registered by the app or config.toml
	import streamlitd.theme : registerColorScheme, resetThemeExtensions, ThemeTokens, Theme;
	scope (exit) resetThemeExtensions();
	ThemeTokens t;
	t.primaryColor = "#0055aa";
	registerColorScheme("authpagetest", "Test", t);
	Theme th;
	th.scheme = "authpagetest";
	auto c = authPageColors(th);
	assert(c[0] == "#0055aa" && c[2] == "#0055aa", c[0]);
	th.scheme = "nope";
	assert(authPageColors(th)[0] == "#ff4b4b");
}

unittest
{
	// [ui]: header controls from the config file, env and CLI (CLI > env > file), validated
	import std.algorithm : canFind;
	import std.exception : assertThrown;
	import std.file : tempDir, write, remove;
	import std.path : buildPath;
	ArgsAction act;
	string helpText;
	auto o = parseServerArgs(["app"], null, act, helpText, false);
	assert(o.ui.rerunButton == "header" && o.ui.settingsButton == "header" && o.ui.rerunShortcut);
	auto cfg = buildPath(tempDir, "streamlitd-ui-test.toml");
	write(cfg, "[ui]\nrerunButton = \"menu\"\nsettingsButton = \"hidden\"\nrerunShortcut = false\n");
	scope (exit) remove(cfg);
	o = parseServerArgs(["app", "--config", cfg], null, act, helpText, false);
	assert(o.ui.rerunButton == "menu" && o.ui.settingsButton == "hidden" && !o.ui.rerunShortcut);
	o = parseServerArgs(["app", "--config", cfg], ["STREAMLITD_UI_RERUNBUTTON": "hidden", "STREAMLITD_UI_RERUNSHORTCUT": "yes"],
		act, helpText, false);
	assert(o.ui.rerunButton == "hidden" && o.ui.rerunShortcut);
	o = parseServerArgs(["app", "--rerun-button", "header", "--settings-button", "menu", "--no-rerun-shortcut"],
		["STREAMLITD_UI_RERUNBUTTON": "hidden"], act, helpText, false);
	assert(o.ui.rerunButton == "header" && o.ui.settingsButton == "menu" && !o.ui.rerunShortcut);
	assertThrown(parseServerArgs(["app", "--rerun-button", "footer"], null, act, helpText, false));
	assertThrown(parseServerArgs(["app"], ["STREAMLITD_UI_SETTINGSBUTTON": "nowhere"], act, helpText, false));
	parseServerArgs(["app", "--help"], null, act, helpText, false);
	assert(helpText.canFind("--rerun-button") && helpText.canFind("--no-rerun-shortcut"));
}
