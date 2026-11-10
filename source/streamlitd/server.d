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

/// Same-origin check for WebSocket and upload requests (protects against cross-site
/// WebSocket hijacking). Requests without an Origin header (non-browser clients) pass.
bool originAllowed(string origin, string host, const string[] allowed)
{
	import std.algorithm : canFind, startsWith;
	if (origin.length == 0)
		return true;
	if (allowed.canFind("*") || allowed.canFind(origin))
		return true;
	foreach (scheme; ["http://", "https://"])
		if (origin.startsWith(scheme) && origin[scheme.length .. $] == host)
			return true;
	return false;
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
	sess.mapTileUrl = g_opts.mapTileUrl;
	sess.mapAttribution = g_opts.mapAttribution;
	sess.allowThemeSwitch = g_opts.allowThemeSwitch;
	g_sessions[sess.id] = sess;
	auto ev = createManualEvent();
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

private string htmlEscapeAttr(string s)
{
	import std.array : replace;
	return s.replace("&", "&amp;").replace(`"`, "&quot;").replace("<", "&lt;").replace(">", "&gt;");
}

private void serveIndex(HTTPServerRequest req, HTTPServerResponse res)
{
	import std.array : replace;
	if (g_auth.required && userFromRequest(g_auth, req).type == Json.Type.null_)
	{
		res.redirect(g_opts.baseUrlPath ~ "/auth/login");
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

/// Start serving `app` and run the event loop (blocks).
int serve(AppFn app, ServerOptions opts = ServerOptions.init)
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
			g_auth = loadAuthConfig(cfgAuth, secrets().get!Json("auth"), opts.baseUrlPath);
		}
		catch (Exception e)
		{
			stderr.writeln("streamlitd: auth configuration error: ", e.msg);
			return 1;
		}
	}
	if (opts.scriptThreads != 0)
		startScriptWorkers(opts.scriptThreads < 0 ? 0 : cast(uint) opts.scriptThreads);

	auto router = new URLRouter(opts.baseUrlPath);
	router.get("/_stcore/health", (HTTPServerRequest req, HTTPServerResponse res) { res.writeBody("ok"); });
	foreach (f; ["/_stcore/favicon", "/_stcore/favicon.svg", "/_stcore/favicon-32.png", "/_stcore/apple-touch-icon.png", "/favicon.ico"])
		router.get(f, &serveFavicon);
	router.get("/_stcore/ws", &handleWSRequest);
	router.get("/static/*", &serveAsset);
	router.get("/_media/:id", &serveMedia);
	router.get("/_components/*", &serveComponent);
	router.post("/_upload/:sid/:wid", &handleUpload);
	if (g_auth.enabled)
		registerAuthRoutes(router, &g_auth);
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

/// What `runMain` should do after parsing the command line.
enum ArgsAction { serve, help, hashPassword }

/// Build the server options from config files, `STREAMLITD_*` environment variables and the
/// command line (precedence: CLI > env > config file > defaults). Throws on invalid input.
/// `helpText` is filled when `--help` was given.
ServerOptions parseServerArgs(string[] args, string[string] env, out ArgsAction action, out string helpText,
	bool readConfigFiles = true)
{
	import std.getopt;
	import std.array : appender;
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
	bool noSwitch, hashPassword;
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
		"color-scheme", "Color scheme: " ~ colorSchemeNames().join(", "), &o.theme.scheme,
		"theme", "Old name of --color-scheme", &o.theme.scheme,
		"design", "Design style: " ~ designNames().join(", "), &o.theme.design,
		"theme-mode", "auto | light | dark", &o.theme.mode,
		"no-theme-switch", "Hide the viewer's appearance menu", &noSwitch,
		"hash-password", "Read a password from stdin and print its hash for secrets.toml", &hashPassword,
		"auth-required", "Require login for the whole app ([auth] must be configured)", &o.authRequired,
		"favicon", "Favicon image file (svg, png, ico, ...) for every page", &o.favicon,
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
	if (noSwitch)
		o.allowThemeSwitch = false;
	if (o.favicon.length && action == ArgsAction.serve)
	{
		immutable(ubyte)[] data;
		string mime;
		loadFavicon(o.favicon, data, mime); // fail at startup, not on the first request
	}
	validateTheme(o.theme);
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
}

/// Parse configuration (config.toml, `STREAMLITD_*` env vars, command line) and serve.
/// Precedence: CLI > env > config file > defaults.
int runMain(AppFn app, string[] args)
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
	return serve(app, o);
}
