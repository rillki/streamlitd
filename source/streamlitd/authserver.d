/// HTTP side of authentication: login page, password login, OIDC (authorization code flow),
/// logout, and the signed session cookie. Configuration follows Streamlit's `[auth]` section
/// (in secrets.toml or config.toml):
///
/// ---
/// [auth]
/// required = true                      # put the whole app behind the login page
/// cookie_secret = "long-random-string"
/// redirect_uri = "https://example.com/oauth2callback"
/// # OIDC providers: either directly in [auth] (one provider) or as named sub-tables
/// [auth.google]
/// client_id = "..."
/// client_secret = "..."
/// server_metadata_url = "https://accounts.google.com/.well-known/openid-configuration"
/// # built-in password users (hash with `./app --hash-password`)
/// [auth.users.alice]
/// password_hash = "pbkdf2_sha256$..."
/// name = "Alice"
/// email = "alice@example.com"
/// ---
module streamlitd.authserver;

import std.algorithm : canFind, sort;
import std.array : array, split;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime : Clock;
import std.uri : encodeComponent;
import vibe.data.json;
import vibe.http.server;
import vibe.http.router;

import streamlitd.auth;
import streamlitd.secrets : deepMerge, Secrets;
import streamlitd.util;

/// One OIDC identity provider.
struct OidcProvider
{
	string name;
	string label;
	string clientId;
	string clientSecret;
	string metadataUrl;
	string scope_ = "openid profile email";
	Json metadata; // fetched lazily
}

/// Resolved auth configuration.
struct AuthConfig
{
	bool required;
	immutable(ubyte)[] cookieSecret;
	string redirectUri;
	OidcProvider[] providers;
	Json users = Json.emptyObject;
	string basePath;
	uint cookieDays = 30;

	bool enabled() const { return providers.length > 0 || users.length > 0; }
	bool hasPasswords() const { return users.length > 0; }
}

enum authCookie = "streamlitd_auth";
enum stateCookie = "streamlitd_oidc";

/// Build the auth config from config.toml `[auth]` merged with secrets.toml `[auth]`.
AuthConfig loadAuthConfig(Json configAuth, Json secretsAuth, string basePath)
{
	AuthConfig c;
	c.basePath = basePath;
	auto a = deepMerge(configAuth.type == Json.Type.object ? configAuth : Json.emptyObject,
		secretsAuth.type == Json.Type.object ? secretsAuth : Json.emptyObject);
	c.required = a["required"].opt!bool(false);
	auto secret = a["cookie_secret"].opt!string(null);
	c.redirectUri = a["redirect_uri"].opt!string(null);
	c.cookieDays = cast(uint) a["cookie_days"].opt!long(30);
	if (a["users"].type == Json.Type.object)
		c.users = a["users"];

	OidcProvider fromTable(string name, Json t)
	{
		OidcProvider p;
		p.name = name;
		p.label = t["label"].opt!string(name == "default" ? "Single sign-on" : name);
		p.clientId = t["client_id"].get!string;
		p.clientSecret = t["client_secret"].opt!string(null);
		p.metadataUrl = t["server_metadata_url"].get!string;
		p.scope_ = t["scope"].opt!string("openid profile email");
		return p;
	}
	if (a["client_id"].type == Json.Type.string)
		c.providers ~= fromTable("default", a);
	string[] names;
	foreach (string k, v; a)
		if (v.type == Json.Type.object && v["client_id"].type == Json.Type.string)
			names ~= k;
	names.sort();
	foreach (k; names)
		c.providers ~= fromTable(k, a[k]);

	if (c.enabled || c.required)
	{
		if (secret is null || secret.length < 16)
			throw new Exception("[auth] cookie_secret (at least 16 characters) is required when auth is configured");
		if (c.providers.length && c.redirectUri is null)
			throw new Exception("[auth] redirect_uri is required for OIDC providers (e.g. http://localhost:8501/oauth2callback)");
		if (!c.enabled)
			throw new Exception("[auth] required = true, but no users or OIDC providers are configured");
	}
	c.cookieSecret = cast(immutable(ubyte)[]) secret;
	return c;
}

/// The logged-in user from the request cookie, or `Json(null)`.
Json userFromRequest(const ref AuthConfig c, HTTPServerRequest req)
{
	if (!c.enabled)
		return Json(null);
	auto v = req.cookies.get(authCookie, null);
	if (v is null)
		return Json(null);
	auto payload = verifySigned(v, c.cookieSecret);
	if (payload is null)
		return Json(null);
	try
	{
		auto j = parseJsonString(payload);
		if (j["exp"].opt!long(0) < Clock.currTime.toUnixTime)
			return Json(null);
		return j;
	}
	catch (Exception)
		return Json(null);
}

private string basePrefix(const ref AuthConfig c) { return c.basePath ~ "/"; }

private void setUserCookie(const ref AuthConfig c, HTTPServerRequest req, HTTPServerResponse res, Json user)
{
	user["exp"] = Clock.currTime.toUnixTime + c.cookieDays * 86_400L;
	auto ck = res.setCookie(authCookie, signValue(user.toString, c.cookieSecret), basePrefix(c));
	ck.httpOnly = true;
	ck.sameSite = Cookie.SameSite.lax;
	ck.maxAge = c.cookieDays * 86_400;
	ck.secure = isHttps(req);
}

private bool isHttps(HTTPServerRequest req)
{
	return req.tls || req.headers.get("X-Forwarded-Proto", "") == "https";
}

// ---------------------------------------------------------------- login page

private string esc(string s)
{
	import std.array : replace;
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace(`"`, "&quot;");
}

private string loginPage(const ref AuthConfig c, string error, string title)
{
	string providers;
	foreach (p; c.providers)
		providers ~= `<a class="sso" href="` ~ esc(basePrefix(c) ~ "auth/login?provider=" ~ encodeComponent(p.name)) ~
			`">Continue with ` ~ esc(p.label) ~ `</a>`;
	string form;
	if (c.hasPasswords)
		form = `<form method="post" action="` ~ esc(basePrefix(c) ~ "auth/login") ~ `">
<label for="u">Username</label><input id="u" name="username" autocomplete="username" required autofocus>
<label for="p">Password</label><input id="p" name="password" type="password" autocomplete="current-password" required>
<button type="submit">Sign in</button></form>`;
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sign in</title><style>
:root{color-scheme:light dark}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font-family:"Source Sans Pro",-apple-system,"Segoe UI",Roboto,sans-serif;background:#f0f2f6;color:#31333f}
@media (prefers-color-scheme:dark){body{background:#0e1117;color:#fafafa}.card{background:#262730!important}input{background:#0e1117!important;color:#fafafa}}
.card{background:#fff;padding:2rem 2.25rem;border-radius:.75rem;box-shadow:0 4px 24px rgba(0,0,0,.08);width:100%;max-width:22rem}
h1{font-size:1.5rem;margin:0 0 1.25rem}label{display:block;font-size:.85rem;margin:.75rem 0 .25rem}
input{width:100%;box-sizing:border-box;padding:.55rem .75rem;border:1px solid rgba(128,128,128,.35);border-radius:.5rem;font:inherit;background:#fff}
button,.sso{display:block;width:100%;box-sizing:border-box;margin-top:1.25rem;padding:.6rem;border:none;border-radius:.5rem;background:#ff4b4b;color:#fff;font:inherit;cursor:pointer;text-align:center;text-decoration:none}
.sso{background:transparent;color:inherit;border:1px solid rgba(128,128,128,.4);margin-top:.6rem}.err{color:#d33;font-size:.9rem;margin:.5rem 0 0}
.sep{text-align:center;font-size:.8rem;opacity:.6;margin:1rem 0 0}</style></head><body><main class="card">
<h1>` ~ esc(title) ~ `</h1>` ~ (error.length ? `<p class="err" role="alert">` ~ esc(error) ~ `</p>` : "") ~ form ~
		(form.length && providers.length ? `<p class="sep">or</p>` : "") ~ providers ~ `</main></body></html>`;
}

// ---------------------------------------------------------------- routes

/// Register `/auth/login`, `/auth/logout` and `/oauth2callback` on the router.
void registerAuthRoutes(URLRouter router, AuthConfig* c)
{
	router.get("/auth/login", (HTTPServerRequest req, HTTPServerResponse res) {
		auto prov = req.query.get("provider", null);
		if (prov is null && !c.hasPasswords && c.providers.length == 1)
			prov = c.providers[0].name;
		if (prov is null)
		{
			res.headers["Cache-Control"] = "no-store";
			res.writeBody(loginPage(*c, null, "Sign in"), "text/html; charset=UTF-8");
			return;
		}
		startOidc(*c, prov, req, res);
	});

	router.post("/auth/login", (HTTPServerRequest req, HTTPServerResponse res) {
		auto user = req.form.get("username", "");
		auto pass = req.form.get("password", "");
		auto u = c.users[user];
		auto hash = u.type == Json.Type.object ? u["password_hash"].opt!string("") : "";
		// verify on a worker thread (PBKDF2 is deliberately slow); unknown users cost the same
		import vibe.core.concurrency : async;
		auto ok = async(&verifyOrDummy, pass, hash).getResult();
		if (!ok || hash.length == 0)
		{
			res.statusCode = 401;
			res.headers["Cache-Control"] = "no-store";
			res.writeBody(loginPage(*c, "Invalid username or password.", "Sign in"), "text/html; charset=UTF-8");
			return;
		}
		auto info = jo("sub", user, "name", u["name"].opt!string(user), "email", u["email"].opt!string(null),
			"provider", "password");
		setUserCookie(*c, req, res, info);
		res.redirect(basePrefix(*c));
	});

	router.get("/oauth2callback", (HTTPServerRequest req, HTTPServerResponse res) {
		finishOidc(*c, req, res);
	});

	router.get("/auth/logout", (HTTPServerRequest req, HTTPServerResponse res) {
		auto ck = res.setCookie(authCookie, null, basePrefix(*c));
		ck.maxAge = 0;
		res.redirect(basePrefix(*c) ~ (c.required ? "auth/login" : ""));
	});
}

private bool verifyOrDummy(string pass, string hash) nothrow
{
	try
	{
		if (hash.length == 0)
		{
			// equalize timing for unknown users
			verifyPassword(pass, "pbkdf2_sha256$" ~ defaultIterations.to!string ~ "$c2FsdHNhbHRzYWx0c2FsdA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
			return false;
		}
		return verifyPassword(pass, hash);
	}
	catch (Exception)
		return false;
}

private OidcProvider* findProvider(ref AuthConfig c, string name)
{
	foreach (ref p; c.providers)
		if (p.name == name)
			return &p;
	return null;
}

private Json providerMetadata(OidcProvider* p)
{
	import vibe.http.client : requestHTTP;
	import vibe.stream.operations : readAllUTF8;
	if (p.metadata.type == Json.Type.object)
		return p.metadata;
	auto r = requestHTTP(p.metadataUrl);
	scope (exit) r.dropBody();
	if (r.statusCode != 200)
		throw new Exception("OIDC metadata request failed: HTTP " ~ r.statusCode.to!string);
	p.metadata = parseJsonString(r.bodyReader.readAllUTF8());
	return p.metadata;
}

private void startOidc(ref AuthConfig c, string provName, HTTPServerRequest req, HTTPServerResponse res)
{
	auto p = findProvider(c, provName);
	if (p is null)
	{
		res.statusCode = 404;
		res.writeBody(loginPage(c, "Unknown login provider.", "Sign in"), "text/html; charset=UTF-8");
		return;
	}
	auto meta = providerMetadata(p);
	import std.base64 : Base64URL;
	auto nonce = Base64URLNoPadding.encode(randomBytes(18)).idup;
	auto state = signValue(jo("p", provName, "n", nonce, "t", Clock.currTime.toUnixTime).toString, c.cookieSecret);
	auto ck = res.setCookie(stateCookie, nonce, basePrefix(c));
	ck.httpOnly = true;
	ck.sameSite = Cookie.SameSite.lax;
	ck.maxAge = 600;
	ck.secure = isHttps(req);
	auto url = meta["authorization_endpoint"].get!string ~ "?response_type=code" ~
		"&client_id=" ~ encodeComponent(p.clientId) ~
		"&redirect_uri=" ~ encodeComponent(c.redirectUri) ~
		"&scope=" ~ encodeComponent(p.scope_) ~
		"&state=" ~ encodeComponent(state) ~
		"&nonce=" ~ encodeComponent(nonce);
	res.redirect(url);
}

/// Decode a JWT payload (no signature check: the token comes straight from the token
/// endpoint over the back channel, which OIDC Core 3.1.3.7 allows).
Json decodeJwtPayload(string jwt)
{
	auto parts = jwt.split(".");
	if (parts.length < 2)
		throw new Exception("malformed id_token");
	return parseJsonString(cast(string) Base64URLNoPadding.decode(parts[1]).idup);
}

private void finishOidc(ref AuthConfig c, HTTPServerRequest req, HTTPServerResponse res)
{
	void fail(string msg)
	{
		res.statusCode = 401;
		res.writeBody(loginPage(c, msg, "Sign in"), "text/html; charset=UTF-8");
	}
	if (req.query.get("error", null) !is null)
		return fail("Login was cancelled or denied: " ~ req.query.get("error", ""));
	auto statePayload = verifySigned(req.query.get("state", ""), c.cookieSecret);
	if (statePayload is null)
		return fail("Invalid login state. Please try again.");
	auto st = parseJsonString(statePayload);
	auto nonce = st["n"].get!string;
	if (req.cookies.get(stateCookie, "") != nonce || Clock.currTime.toUnixTime - st["t"].get!long > 600)
		return fail("Login session expired. Please try again.");
	auto p = findProvider(c, st["p"].get!string);
	if (p is null)
		return fail("Unknown login provider.");
	auto meta = providerMetadata(p);

	import vibe.http.client : requestHTTP;
	import vibe.http.common : HTTPMethod;
	import vibe.stream.operations : readAllUTF8;
	auto form = "grant_type=authorization_code&code=" ~ encodeComponent(req.query.get("code", "")) ~
		"&redirect_uri=" ~ encodeComponent(c.redirectUri) ~ "&client_id=" ~ encodeComponent(p.clientId) ~
		(p.clientSecret.length ? "&client_secret=" ~ encodeComponent(p.clientSecret) : "");
	Json tok;
	auto r = requestHTTP(meta["token_endpoint"].get!string, (scope rq) {
		rq.method = HTTPMethod.POST;
		rq.headers["Accept"] = "application/json";
		rq.writeBody(cast(const(ubyte)[]) form, "application/x-www-form-urlencoded");
	});
	scope (exit) r.dropBody();
	auto body_ = r.bodyReader.readAllUTF8();
	if (r.statusCode != 200)
		return fail("Token exchange failed (HTTP " ~ r.statusCode.to!string ~ ").");
	tok = parseJsonString(body_);
	auto idt = tok["id_token"].opt!string(null);
	if (idt is null)
		return fail("The provider did not return an id_token.");
	auto claims = decodeJwtPayload(idt);
	auto aud = claims["aud"];
	bool audOk = aud.type == Json.Type.string ? aud.get!string == p.clientId
		: (aud.type == Json.Type.array && aud[].canFind!(a => a.type == Json.Type.string && a.get!string == p.clientId));
	if (meta["issuer"].type == Json.Type.string && claims["iss"].opt!string("") != meta["issuer"].get!string)
		return fail("id_token issuer mismatch.");
	if (!audOk)
		return fail("id_token audience mismatch.");
	if (claims["exp"].opt!long(long.max) < Clock.currTime.toUnixTime)
		return fail("id_token expired.");
	if (claims["nonce"].opt!string(nonce) != nonce)
		return fail("id_token nonce mismatch.");
	auto info = jo("sub", claims["sub"].opt!string(null), "name", claims["name"].opt!string(claims["email"].opt!string(null)),
		"email", claims["email"].opt!string(null), "picture", claims["picture"].opt!string(null), "provider", p.name);
	auto ck = res.setCookie(stateCookie, null, basePrefix(c));
	ck.maxAge = 0;
	setUserCookie(c, req, res, info);
	res.redirect(basePrefix(c));
}

unittest
{
	auto c = loadAuthConfig(Json.emptyObject, parseJsonString(`{"cookie_secret":"0123456789abcdef!",
		"redirect_uri":"http://h/oauth2callback",
		"google":{"client_id":"cid","client_secret":"s","server_metadata_url":"https://x/.well-known"},
		"users":{"ann":{"password_hash":"x","name":"Ann"}}}`), "");
	assert(c.enabled && c.hasPasswords && c.providers.length == 1 && c.providers[0].name == "google");
	import std.exception : assertThrown;
	assertThrown(loadAuthConfig(Json.emptyObject, parseJsonString(`{"users":{"a":{}}}`), ""));
	assertThrown(loadAuthConfig(parseJsonString(`{"required":true,"cookie_secret":"0123456789abcdef!"}`), Json.emptyObject, ""));
	auto off = loadAuthConfig(Json.emptyObject, Json.emptyObject, "");
	assert(!off.enabled);
	auto payload = decodeJwtPayload("eyJhbGciOiJub25lIn0." ~ Base64URLNoPadding.encode(cast(const(ubyte)[]) `{"sub":"1"}`).idup ~ ".");
	assert(payload["sub"].get!string == "1");
}
