/// HTTP side of authentication: the login, sign-up, account and password-reset pages, OIDC
/// (authorization code flow), logout, and the signed session cookie. Configuration follows
/// Streamlit's `[auth]` section (in secrets.toml or config.toml):
///
/// ---
/// [auth]
/// required = true                      # put the whole app behind the login page
/// registration = "first_admin"         # sign-up: off | first_admin | open | approval | invite
/// cookie_secret = "long-random-string" # optional: generated once into .streamlitd/auth_secret
/// redirect_uri = "https://example.com/oauth2callback"
/// # OIDC providers: either directly in [auth] (one provider) or as named sub-tables
/// [auth.google]
/// client_id = "..."
/// client_secret = "..."
/// server_metadata_url = "https://accounts.google.com/.well-known/openid-configuration"
/// # users with manual hashes (`./app --hash-password`), read-only
/// [auth.users.alice]
/// password_hash = "pbkdf2_sha256$..."
/// name = "Alice"
/// email = "alice@example.com"
/// roles = ["admin"]
/// ---
module streamlitd.authserver;

import std.algorithm : canFind, sort;
import std.array : array, split;
import std.base64 : Base64URLNoPadding;
import std.conv : to;
import std.datetime : Clock;
import std.stdio : stderr;
import std.uri : encodeComponent;
import vibe.data.json;
import vibe.http.server;
import vibe.http.router;

import streamlitd.auth;
import streamlitd.accounts;
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
	/// Accounts: sign-up, the user store, roles (always set by `loadAuthConfig`).
	Accounts accounts;
	/// Failed-login counters.
	LoginThrottle throttle;
	/// Successful sign-ups per address (`[auth] signups_per_hour`).
	LoginThrottle signups;
	/// Take the client address from `X-Forwarded-For`, as added by the proxy (`[server] trustProxy`).
	bool trustProxy;
	/// Extra origins allowed to post the forms (`[server] allowedOrigins`).
	string[] allowedOrigins;
	/// Colors of the login pages (the app's color scheme): primary and text on it, light and dark.
	string[4] pageColors = ["#ff4b4b", "#ffffff", "#ff4b4b", "#ffffff"];

	/// There is an `[auth]` section (the CLI user commands work then).
	bool configured;

	/// The user store had accounts when the server started (counted once: `enabled` runs on
	/// every request, and a database store would be queried each time).
	bool storeUsersAtStart;

	/// Is there any way to log in (users, providers, sign-up, or accounts in the user store)?
	/// Decided at startup, like the login routes.
	bool enabled() const
	{
		return providers.length > 0 || users.length > 0 || storeUsersAtStart
			|| (accounts !is null && accounts.settings.registration != Registration.off);
	}

	/// Is there a password login (config users, sign-up, or password users in the store)?
	bool hasPasswords()
	{
		if (users.length > 0 || (accounts !is null && accounts.settings.registration != Registration.off))
			return true;
		if (accounts !is null)
			foreach (u; accounts.users)
				if (!u.provider.length)
					return true;
		return false;
	}
}

enum authCookie = "streamlitd_auth";
enum stateCookie = "streamlitd_oidc";

/// Build the auth config from config.toml `[auth]` merged with secrets.toml `[auth]`.
/// `store` overrides the user store (default: the one from `useUserStore`, else `users_file`).
AuthConfig loadAuthConfig(Json configAuth, Json secretsAuth, string basePath, UserStore store = null)
{
	AuthConfig c;
	c.basePath = basePath;
	auto a = deepMerge(configAuth.type == Json.Type.object ? configAuth : Json.emptyObject,
		secretsAuth.type == Json.Type.object ? secretsAuth : Json.emptyObject);
	immutable hasSection = a.length > 0; // before any a["..."]: vibe's opIndex adds missing keys
	c.configured = hasSection;
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

	// accounts: with an [auth] section but no users or providers, sign-up of the first admin is on
	AccountSettings s;
	s.registration = a["registration"].type == Json.Type.string ? parseRegistration(a["registration"].get!string)
		: hasSection && !c.users.length && !c.providers.length ? Registration.firstAdmin : Registration.off;
	s.usersFile = a["users_file"].opt!string(s.usersFile);
	s.signupFields = strings(a["signup_fields"], s.signupFields);
	foreach (f; s.signupFields)
		if (f != "name" && f != "email")
			throw new Exception(`[auth] signup_fields may contain "name" and "email", not "` ~ f ~ `"`);
	s.requireEmail = a["require_email"].opt!bool(false);
	s.passwordMinLength = cast(size_t) a["password_min_length"].opt!long(8);
	if (s.passwordMinLength < 1 || s.passwordMinLength > 128)
		throw new Exception("[auth] password_min_length must be between 1 and 128");
	s.allowedEmailDomains = strings(a["allowed_email_domains"], null);
	s.defaultRoles = strings(a["default_roles"], null);
	s.admins = strings(a["admins"], null);
	auto rl = a["rate_limit"];
	if (rl.type == Json.Type.object)
	{
		s.maxFailures = cast(uint) rl["max_failures"].opt!long(s.maxFailures);
		s.maxIpFailures = cast(uint) rl["max_ip_failures"].opt!long(s.maxIpFailures);
		s.throttleMinutes = cast(uint) rl["minutes"].opt!long(s.throttleMinutes);
	}
	if (a["signups_per_hour"].type == Json.Type.int_)
		s.signupsPerHour = cast(uint) a["signups_per_hour"].get!long;

	if (secret is null && hasSection)
		secret = readOrCreateSecret(secretPathFor(s.usersFile)); // kept next to the user store
	if (store is null)
		store = customUserStore();
	if (store is null)
		store = hasSection ? new JsonFileUserStore(s.usersFile) : new MemoryUserStore;
	immutable storeUsers = store.count > 0;
	c.storeUsersAtStart = storeUsers;
	if (c.users.length || c.providers.length || c.required || s.registration != Registration.off || storeUsers)
	{
		if (secret is null || secret.length < 16)
			throw new Exception("[auth] cookie_secret (at least 16 characters) is required when auth is configured");
		if (c.providers.length && c.redirectUri is null)
			throw new Exception("[auth] redirect_uri is required for OIDC providers (e.g. http://localhost:8501/oauth2callback)");
		if (!c.users.length && !c.providers.length && s.registration == Registration.off && !storeUsers)
			throw new Exception("[auth] required = true, but there are no users (secrets.toml or the user store), " ~
				"OIDC providers or registration; add a user with --add-user or set registration");
	}
	c.cookieSecret = cast(immutable(ubyte)[]) secret;
	c.accounts = new Accounts(s, store, c.users, c.cookieSecret, basePath);
	c.throttle = new LoginThrottle(s.maxFailures, s.maxIpFailures, s.throttleMinutes);
	c.signups = new LoginThrottle(0, s.signupsPerHour, 60);
	return c;
}

private string[] strings(Json j, string[] def)
{
	if (j.type != Json.Type.array)
		return def;
	string[] r;
	foreach (e; j)
		r ~= e.get!string;
	return r;
}

/// `auth_secret` next to the user file.
string secretPathFor(string usersFile)
{
	import std.path : buildPath, dirName;
	return buildPath(usersFile.dirName, "auth_secret");
}

/// Read the generated cookie secret, or create it (random, mode 0600).
private string readOrCreateSecret(string path)
{
	import std.file : exists, readText, write, mkdirRecurse;
	import std.path : dirName;
	import std.string : strip;
	if (path.exists)
		return readText(path).strip;
	auto s = randomCode(32);
	if (path.dirName.length && !path.dirName.exists)
		mkdirRecurse(path.dirName);
	write(path, s ~ "\n");
	restrictPermissions(path);
	stderr.writeln("streamlitd: auth: generated a cookie secret in ", path, " (set [auth] cookie_secret to use your own)");
	return s;
}

/// The logged-in user from the request cookie, or `Json(null)`. Accounts from the user store
/// are checked on every request (deleted, disabled or logged out everywhere → `null`), and
/// `roles` and `username` are added.
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
		return c.accounts is null ? j : (cast() c.accounts).resolve(j);
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

private void clearUserCookie(const ref AuthConfig c, HTTPServerResponse res)
{
	auto ck = res.setCookie(authCookie, null, basePrefix(c));
	ck.maxAge = 0;
}

private bool isHttps(HTTPServerRequest req)
{
	return req.tls || req.headers.get("X-Forwarded-Proto", "") == "https";
}

/// The client's address: the peer, or behind a trusted proxy the last `X-Forwarded-For` entry (the
/// one the proxy appended; earlier entries come from the client and can be forged).
string clientIp(const ref AuthConfig c, HTTPServerRequest req)
{
	import std.string : strip;
	if (c.trustProxy)
	{
		auto f = req.headers.get("X-Forwarded-For", "");
		if (f.length)
			return f.split(",")[$ - 1].strip;
	}
	try
		return req.clientAddress.toAddressString(); // without the port (it changes per connection)
	catch (Exception)
		return req.peer;
}

/// Log an auth event (never passwords).
private void authLog(string what)
{
	version (unittest) return; // keep the test output clean
	else try stderr.writeln("streamlitd: auth: ", what);
	catch (Exception) {}
}

// ---------------------------------------------------------------- forms: CSRF tokens

/// A form token bound to its purpose and the user (`sub`, or "" before login); valid 4 hours.
private string csrfToken(const ref AuthConfig c, string purpose, string sub)
{
	return signValue(Json(["p": Json(purpose), "s": Json(sub), "t": Json(Clock.currTime.toUnixTime)]).toString, c.cookieSecret);
}

/// Check the posted form token and the Origin header.
private bool formOk(const ref AuthConfig c, HTTPServerRequest req, string purpose, string sub)
{
	if (!originAllowed(req.headers.get("Origin", ""), req.host, c.allowedOrigins))
		return false;
	auto p = verifySigned(req.form.get("csrf", ""), c.cookieSecret);
	if (p is null)
		return false;
	try
	{
		auto j = parseJsonString(p);
		return j["p"].get!string == purpose && j["s"].get!string == sub
			&& Clock.currTime.toUnixTime - j["t"].get!long < 4 * 3600;
	}
	catch (Exception)
		return false;
}

// ---------------------------------------------------------------- pages

private string esc(string s)
{
	import std.array : replace;
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace(`"`, "&quot;");
}

private string q(string s) { return encodeComponent(s); }

/// The page frame shared by all auth pages.
private string page(const ref AuthConfig c, string title, string body_, string error = null, string notice = null)
{
	return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>` ~ esc(title) ~ `</title><style>
:root{color-scheme:light dark;--p:` ~ c.pageColors[0] ~ `;--on-p:` ~ c.pageColors[1] ~ `}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font-family:"Source Sans Pro",-apple-system,"Segoe UI",Roboto,sans-serif;background:#f0f2f6;color:#31333f}
@media (prefers-color-scheme:dark){:root{--p:` ~ c.pageColors[2] ~ `;--on-p:` ~ c.pageColors[3] ~ `}body{background:#0e1117;color:#fafafa}.card{background:#262730!important}input{background:#0e1117!important;color:#fafafa}.muted{color:#b4b6c0!important}}
.card{background:#fff;padding:2rem 2.25rem;border-radius:.75rem;box-shadow:0 4px 24px rgba(0,0,0,.08);width:100%;max-width:23rem;margin:1rem}
h1{font-size:1.5rem;margin:0 0 1.25rem}h2{font-size:1.1rem;margin:1.75rem 0 .25rem}label{display:block;font-size:.85rem;margin:.75rem 0 .25rem}
input{width:100%;box-sizing:border-box;padding:.55rem .75rem;border:1px solid rgba(128,128,128,.45);border-radius:.5rem;font:inherit;background:#fff;color:#31333f}
input:focus-visible,button:focus-visible,a:focus-visible{outline:2px solid var(--p);outline-offset:2px}
button,.sso{display:block;width:100%;box-sizing:border-box;margin-top:1.25rem;padding:.6rem;border:none;border-radius:.5rem;background:var(--p);color:var(--on-p);font:inherit;font-weight:600;cursor:pointer;text-align:center;text-decoration:none}
.sso,button.secondary{background:transparent;color:inherit;border:1px solid rgba(128,128,128,.5);margin-top:.6rem;font-weight:400}
.err{color:#c62828;font-size:.95rem;margin:.5rem 0 0}@media (prefers-color-scheme:dark){.err{color:#ff8a80}}
.ok{font-size:.95rem;margin:.5rem 0 0;padding:.5rem .75rem;border-radius:.5rem;background:rgba(33,195,84,.15)}
.muted{color:#5c5f6b;font-size:.85rem}.links{margin-top:1.25rem;font-size:.9rem;text-align:center}.links a{color:inherit}
.sep{text-align:center;font-size:.8rem;opacity:.7;margin:1rem 0 0}dl{display:grid;grid-template-columns:max-content 1fr;gap:.3rem 1rem;margin:0}
dt{opacity:.75}dd{margin:0;overflow-wrap:anywhere}</style></head><body><main class="card">
<h1>` ~ esc(title) ~ `</h1>` ~ (error.length ? `<p class="err" role="alert">` ~ esc(error) ~ `</p>` : "")
		~ (notice.length ? `<p class="ok" role="status">` ~ esc(notice) ~ `</p>` : "") ~ body_ ~ `</main></body></html>`;
}

private void writePage(HTTPServerResponse res, string html, int status = 200)
{
	res.statusCode = status;
	res.headers["Cache-Control"] = "no-store";
	res.headers["X-Frame-Options"] = "DENY";
	res.writeBody(html, "text/html; charset=UTF-8");
}

private string hidden(string name, string value)
{
	return `<input type="hidden" name="` ~ name ~ `" value="` ~ esc(value) ~ `">`;
}

private string field(string id, string label, string name, string type = "text", string value = null,
	string autocomplete = null, bool required = false, bool autofocus = false, string hint = null)
{
	return `<label for="` ~ id ~ `">` ~ esc(label) ~ `</label><input id="` ~ id ~ `" name="` ~ name ~ `" type="` ~ type ~ `"`
		~ (value.length ? ` value="` ~ esc(value) ~ `"` : "") ~ (autocomplete.length ? ` autocomplete="` ~ autocomplete ~ `"` : "")
		~ (required ? " required" : "") ~ (autofocus ? " autofocus" : "")
		~ (hint.length ? ` aria-describedby="` ~ id ~ `-hint"` : "") ~ `>`
		~ (hint.length ? `<div id="` ~ id ~ `-hint" class="muted">` ~ esc(hint) ~ `</div>` : "");
}

private string ssoButtons(const ref AuthConfig c, string next, string invite)
{
	string r;
	foreach (p; c.providers)
		r ~= `<a class="sso" href="` ~ esc(basePrefix(c) ~ "auth/login?provider=" ~ q(p.name)
			~ (next.length ? "&next=" ~ q(next) : "") ~ (invite.length ? "&invite=" ~ q(invite) : "")) ~ `">Continue with ` ~ esc(p.label) ~ `</a>`;
	return r;
}

private string loginPage(AuthConfig* c, string error, string next, string username = null)
{
	string form;
	if (c.hasPasswords)
		form = `<form method="post" action="` ~ esc(basePrefix(*c) ~ "auth/login") ~ `">`
			~ hidden("csrf", csrfToken(*c, "login", "")) ~ hidden("next", next)
			~ field("u", "Username", "username", "text", username, "username", true, !username.length)
			~ field("p", "Password", "password", "password", null, "current-password", true, username.length > 0)
			~ `<button type="submit">Sign in</button></form>`;
	auto sso = ssoButtons(*c, next, null);
	string links;
	if (c.accounts.signupOpen)
		links = `<p class="links">No account? <a href="` ~ esc(basePrefix(*c) ~ "auth/register" ~ (next.length ? "?next=" ~ q(next) : ""))
			~ `" data-testid="register-link">Create one</a></p>`;
	return page(*c, "Sign in", form ~ (form.length && sso.length ? `<p class="sep">or</p>` : "") ~ sso ~ links, error);
}

private string registerPage(AuthConfig* c, string error, string next, string invite, string[string] values = null)
{
	auto s = c.accounts.settings;
	immutable first = !c.accounts.hasAdmin;
	immutable askName = s.signupFields.canFind("name");
	immutable askEmail = s.signupFields.canFind("email") || s.requireEmail || s.allowedEmailDomains.length > 0;
	string v(string k) { return values is null ? null : values.get(k, null); }
	string domains;
	if (s.allowedEmailDomains.length)
	{
		import std.array : join;
		domains = "Addresses from " ~ s.allowedEmailDomains.join(", ");
	}
	auto form = `<form method="post" action="` ~ esc(basePrefix(*c) ~ "auth/register") ~ `">`
		~ hidden("csrf", csrfToken(*c, "register", "")) ~ hidden("next", next)
		~ field("u", "Username", "username", "text", v("username"), "username", true, true,
			"3–64 characters: letters, digits, . _ -")
		~ (askName ? field("n", "Full name", "name", "text", v("name"), "name") : "")
		~ (askEmail ? field("e", "Email" ~ (s.requireEmail || s.allowedEmailDomains.length ? "" : " (optional)"), "email", "email",
			v("email"), "email", s.requireEmail || s.allowedEmailDomains.length > 0, false, domains) : "")
		~ field("p", "Password", "password", "password", null, "new-password", true, false,
			"At least " ~ s.passwordMinLength.to!string ~ " characters")
		~ field("p2", "Repeat the password", "password2", "password", null, "new-password", true)
		~ (c.accounts.inviteRequired ? field("i", "Invite code", "invite", "text", invite, "off", true) : "")
		~ `<button type="submit">Create account</button></form>`;
	auto sso = ssoButtons(*c, next, invite);
	auto note = first ? `<p class="muted" data-testid="first-admin-note">The first account becomes the administrator of this app.</p>`
		: s.registration == Registration.approval ? `<p class="muted">An administrator approves new accounts before you can sign in.</p>` : "";
	return page(*c, "Create account", note ~ form ~ (sso.length ? `<p class="sep">or</p>` ~ sso : "")
		~ `<p class="links">Have an account? <a href="` ~ esc(basePrefix(*c) ~ "auth/login" ~ (next.length ? "?next=" ~ q(next) : ""))
		~ `">Sign in</a></p>`, error);
}

private string accountPage(AuthConfig* c, Json user, string error, string notice)
{
	auto sub = user["sub"].opt!string("");
	auto provider = user["provider"].opt!string("password");
	auto uname = user["username"].opt!string(sub);
	auto su = user["store"].opt!bool(false) && provider == "password" ? c.accounts.user(uname) : null;
	string roles;
	foreach (r; user["roles"].opt!(Json[])(null))
		roles ~= (roles.length ? ", " : "") ~ r.get!string;
	auto info = `<dl data-testid="account-info"><dt>Username</dt><dd>` ~ esc(uname) ~ `</dd>`
		~ `<dt>Signed in with</dt><dd>` ~ esc(provider == "password" ? "password" : provider) ~ `</dd>`
		~ (roles.length ? `<dt>Roles</dt><dd>` ~ esc(roles) ~ `</dd>` : "") ~ `</dl>`;
	string forms;
	auto action = esc(basePrefix(*c) ~ "auth/account");
	if (su !is null)
	{
		auto tok = csrfToken(*c, "account", sub);
		forms ~= `<h2>Profile</h2><form method="post" action="` ~ action ~ `">` ~ hidden("csrf", tok) ~ hidden("action", "profile")
			~ field("n", "Full name", "name", "text", su.name, "name")
			~ field("e", "Email", "email", "email", su.email, "email", c.accounts.settings.requireEmail)
			~ `<button type="submit">Save profile</button></form>`;
		forms ~= `<h2>Password</h2><form method="post" action="` ~ action ~ `">` ~ hidden("csrf", tok) ~ hidden("action", "password")
			~ field("pc", "Current password", "current", "password", null, "current-password", true)
			~ field("pn", "New password", "password", "password", null, "new-password", true, false,
				"At least " ~ c.accounts.settings.passwordMinLength.to!string ~ " characters")
			~ field("pn2", "Repeat the new password", "password2", "password", null, "new-password", true)
			~ `<button type="submit">Change password</button></form>`;
		forms ~= `<h2>Sessions</h2><form method="post" action="` ~ action ~ `">` ~ hidden("csrf", tok) ~ hidden("action", "logout_all")
			~ `<p class="muted">Ends your login on every device and browser, including this one.</p>`
			~ `<button type="submit" class="secondary">Log out everywhere</button></form>`;
	}
	else
		forms ~= `<p class="muted">` ~ (provider == "password"
			? "This account is set up by the administrator of the app; ask them to change it."
			: "Your name, email and password are managed by " ~ esc(provider) ~ ".") ~ `</p>`;
	return page(*c, "Your account", info ~ forms ~ `<p class="links"><a href="` ~ esc(basePrefix(*c)) ~ `">Back to the app</a> · <a href="`
		~ esc(basePrefix(*c) ~ "auth/logout") ~ `">Log out</a></p>`, error, notice);
}

private string resetPage(AuthConfig* c, string token, string error)
{
	auto form = `<form method="post" action="` ~ esc(basePrefix(*c) ~ "auth/reset") ~ `">` ~ hidden("csrf", csrfToken(*c, "reset", ""))
		~ hidden("token", token)
		~ field("p", "New password", "password", "password", null, "new-password", true, true,
			"At least " ~ c.accounts.settings.passwordMinLength.to!string ~ " characters")
		~ field("p2", "Repeat the new password", "password2", "password", null, "new-password", true)
		~ `<button type="submit">Set password</button></form>`;
	return page(*c, "Set a new password", form, error);
}

// ---------------------------------------------------------------- routes

private string throttleMessage(AuthConfig* c)
{
	return "Too many failed attempts. Please wait " ~ c.accounts.settings.throttleMinutes.to!string ~ " minutes and try again.";
}

/// Register `/auth/login`, `/auth/register`, `/auth/account`, `/auth/reset`, `/auth/logout` and
/// `/oauth2callback` on the router.
void registerAuthRoutes(URLRouter router, AuthConfig* c)
{
	router.get("/auth/login", (HTTPServerRequest req, HTTPServerResponse res) {
		auto next = req.query.get("next", "");
		auto prov = req.query.get("provider", null);
		if (prov is null && !c.hasPasswords && c.providers.length == 1)
			prov = c.providers[0].name;
		if (prov is null)
			return writePage(res, loginPage(c, null, next));
		startOidc(*c, prov, req, res, next, req.query.get("invite", null));
	});

	router.post("/auth/login", (HTTPServerRequest req, HTTPServerResponse res) {
		import std.string : strip;
		auto user = req.form.get("username", "").strip;
		auto pass = req.form.get("password", "");
		auto next = req.form.get("next", "");
		auto ip = clientIp(*c, req);
		if (!formOk(*c, req, "login", ""))
			return writePage(res, loginPage(c, "The form expired. Please try again.", next, user), 403);
		if (c.throttle.blocked(user, ip))
		{
			authLog("login blocked (too many failures) user=" ~ user ~ " ip=" ~ ip);
			return writePage(res, loginPage(c, throttleMessage(c), next, user), 429);
		}
		Json info;
		final switch (c.accounts.checkLogin(user, pass, info))
		{
			case LoginResult.ok:
				break;
			case LoginResult.invalid:
				c.throttle.fail(user, ip);
				authLog("login failed user=" ~ user ~ " ip=" ~ ip);
				return writePage(res, loginPage(c, "Invalid username or password.", next, user), 401);
			case LoginResult.pending:
				return writePage(res, loginPage(c, "Your account is waiting for an administrator's approval.", next, user), 403);
			case LoginResult.disabled:
				authLog("login refused (disabled) user=" ~ user ~ " ip=" ~ ip);
				return writePage(res, loginPage(c, "This account is disabled.", next, user), 403);
		}
		c.throttle.succeed(user);
		authLog("login user=" ~ info["sub"].get!string ~ " ip=" ~ ip);
		setUserCookie(*c, req, res, info);
		res.redirect(safeNext(next, c.basePath));
	});

	router.get("/auth/register", (HTTPServerRequest req, HTTPServerResponse res) {
		auto next = req.query.get("next", "");
		if (!c.accounts.signupOpen)
			return writePage(res, page(*c, "Create account", `<p>Sign-up is closed. Please ask an administrator for an account.</p>`
				~ `<p class="links"><a href="` ~ esc(basePrefix(*c) ~ "auth/login") ~ `">Sign in</a></p>`), 403);
		writePage(res, registerPage(c, null, next, req.query.get("invite", null)));
	});

	router.post("/auth/register", (HTTPServerRequest req, HTTPServerResponse res) {
		import std.string : strip;
		auto f = req.form;
		auto next = f.get("next", "");
		auto ip = clientIp(*c, req);
		string[string] values = ["username": f.get("username", ""), "name": f.get("name", ""), "email": f.get("email", "")];
		auto invite = f.get("invite", "");
		string err(string msg, int status)
		{
			writePage(res, registerPage(c, msg, next, invite, values), status);
			return null;
		}
		if (!formOk(*c, req, "register", ""))
			return cast(void) err("The form expired. Please try again.", 403);
		if (c.throttle.blocked(null, ip))
			return cast(void) err(throttleMessage(c), 429);
		if (c.signups !is null && c.signups.blocked(null, ip))
		{
			authLog("sign-up blocked (too many from this address) ip=" ~ ip);
			return cast(void) err("Too many accounts were created from your address. Please try again later.", 429);
		}
		if (f.get("password", "") != f.get("password2", ""))
			return cast(void) err("The passwords do not match.", 400);
		StoredUser u;
		try
			u = c.accounts.register(values["username"], f.get("password", ""), values["name"], values["email"], invite);
		catch (AccountError e)
		{
			import std.algorithm : startsWith;
			if (e.msg.startsWith("This invite"))
				c.throttle.fail(null, ip); // guessing invite codes counts as a failure
			return cast(void) err(e.msg, 400);
		}
		if (c.signups !is null)
			c.signups.fail(null, ip); // counts sign-ups, not failures
		authLog("sign-up user=" ~ u.username ~ (u.isAdmin ? " (admin)" : "") ~ (u.pending ? " (pending)" : "") ~ " ip=" ~ ip);
		if (u.pending)
			return writePage(res, page(*c, "Thanks for signing up", `<p data-testid="pending">Your account <b>` ~ esc(u.username)
				~ `</b> is waiting for an administrator's approval. You can sign in once it is approved.</p><p class="links"><a href="`
				~ esc(basePrefix(*c) ~ "auth/login") ~ `">Sign in</a></p>`));
		setUserCookie(*c, req, res, c.accounts.claimsOf(u));
		res.redirect(safeNext(next, c.basePath));
	});

	router.get("/auth/account", (HTTPServerRequest req, HTTPServerResponse res) {
		auto user = userFromRequest(*c, req);
		if (user.type != Json.Type.object)
			return res.redirect(basePrefix(*c) ~ "auth/login?next=" ~ q(c.basePath ~ "/auth/account"));
		string notice;
		switch (req.query.get("saved", ""))
		{
			case "profile": notice = "Your profile was saved."; break;
			case "password": notice = "Your password was changed. Other devices were logged out."; break;
			default: break;
		}
		writePage(res, accountPage(c, user, null, notice));
	});

	router.post("/auth/account", (HTTPServerRequest req, HTTPServerResponse res) {
		auto user = userFromRequest(*c, req);
		if (user.type != Json.Type.object)
			return res.redirect(basePrefix(*c) ~ "auth/login");
		auto sub = user["sub"].opt!string("");
		auto uname = user["username"].opt!string(sub);
		auto ip = clientIp(*c, req);
		if (!formOk(*c, req, "account", sub))
			return writePage(res, accountPage(c, user, "The form expired. Please try again.", null), 403);
		auto f = req.form;
		try
		{
			switch (f.get("action", ""))
			{
				case "profile":
					c.accounts.updateProfile(uname, f.get("name", ""), f.get("email", ""));
					return res.redirect(basePrefix(*c) ~ "auth/account?saved=profile");
				case "password":
					if (c.throttle.blocked(uname, ip))
						return writePage(res, accountPage(c, user, throttleMessage(c), null), 429);
					if (f.get("password", "") != f.get("password2", ""))
						return writePage(res, accountPage(c, user, "The new passwords do not match.", null), 400);
					Json claims;
					try
						claims = c.accounts.changePassword(uname, f.get("current", ""), f.get("password", ""));
					catch (AccountError e)
					{
						import std.algorithm : startsWith;
						if (e.msg.startsWith("The current password"))
							c.throttle.fail(uname, ip);
						throw e;
					}
					authLog("password changed user=" ~ uname ~ " ip=" ~ ip);
					setUserCookie(*c, req, res, claims); // this browser stays logged in
					return res.redirect(basePrefix(*c) ~ "auth/account?saved=password");
				case "logout_all":
					c.accounts.logoutEverywhere(uname);
					authLog("logged out everywhere user=" ~ uname);
					clearUserCookie(*c, res);
					return res.redirect(basePrefix(*c) ~ "auth/login");
				default:
					return writePage(res, accountPage(c, user, "Unknown action.", null), 400);
			}
		}
		catch (AccountError e)
			return writePage(res, accountPage(c, user, e.msg, null), 400);
	});

	router.get("/auth/reset", (HTTPServerRequest req, HTTPServerResponse res) {
		auto token = req.query.get("token", "");
		if (c.accounts.resetTokenUser(token) is null)
			return writePage(res, page(*c, "Set a new password", `<p>This link is not valid any more. Please ask an administrator for a new one.</p>`
				~ `<p class="links"><a href="` ~ esc(basePrefix(*c) ~ "auth/login") ~ `">Sign in</a></p>`), 410);
		writePage(res, resetPage(c, token, null));
	});

	router.post("/auth/reset", (HTTPServerRequest req, HTTPServerResponse res) {
		auto f = req.form;
		auto token = f.get("token", "");
		auto ip = clientIp(*c, req);
		if (!formOk(*c, req, "reset", ""))
			return writePage(res, resetPage(c, token, "The form expired. Please try again."), 403);
		if (c.throttle.blocked(null, ip))
			return writePage(res, resetPage(c, token, throttleMessage(c)), 429);
		if (f.get("password", "") != f.get("password2", ""))
			return writePage(res, resetPage(c, token, "The passwords do not match."), 400);
		Json claims;
		try
			claims = c.accounts.resetPassword(token, f.get("password", ""));
		catch (AccountError e)
		{
			c.throttle.fail(null, ip);
			return writePage(res, resetPage(c, token, e.msg), 400);
		}
		authLog("password reset user=" ~ claims["sub"].get!string ~ " ip=" ~ ip);
		setUserCookie(*c, req, res, claims);
		res.redirect(basePrefix(*c));
	});

	router.get("/oauth2callback", (HTTPServerRequest req, HTTPServerResponse res) {
		finishOidc(*c, req, res);
	});

	router.get("/auth/logout", (HTTPServerRequest req, HTTPServerResponse res) {
		clearUserCookie(*c, res);
		res.redirect(basePrefix(*c) ~ (c.required ? "auth/login" : ""));
	});
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

private void startOidc(ref AuthConfig c, string provName, HTTPServerRequest req, HTTPServerResponse res,
	string next, string invite)
{
	auto p = findProvider(c, provName);
	if (p is null)
		return writePage(res, loginPage(&c, "Unknown login provider.", next), 404);
	auto meta = providerMetadata(p);
	auto nonce = Base64URLNoPadding.encode(randomBytes(18)).idup;
	auto st = Json(["p": Json(provName), "n": Json(nonce), "t": Json(Clock.currTime.toUnixTime)]);
	if (next.length)
		st["x"] = next;
	if (invite.length)
		st["i"] = invite;
	auto state = signValue(st.toString, c.cookieSecret);
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
		writePage(res, loginPage(&c, msg, null), 401);
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
	auto sub = claims["sub"].opt!string(null);
	auto email = claims["email"].opt!string(null);
	auto name = claims["name"].opt!string(email);
	auto picture = claims["picture"].opt!string(null);
	Json info;
	try
		info = c.accounts.oidcSignIn(p.name, sub, name, email, picture, st["i"].opt!string(null));
	catch (AccountError e)
	{
		authLog("sign-in refused provider=" ~ p.name ~ " sub=" ~ sub ~ ": " ~ e.msg);
		return fail(e.msg);
	}
	catch (Exception e)
	{
		// the store could not be written (e.g. a read-only file system): log in without it
		authLog("could not record the user in the user store: " ~ e.msg);
		info = jo("sub", sub, "name", name, "email", email, "picture", picture, "provider", p.name);
	}
	auto ck = res.setCookie(stateCookie, null, basePrefix(c));
	ck.maxAge = 0;
	authLog("login provider=" ~ p.name ~ " sub=" ~ sub ~ " ip=" ~ clientIp(c, req));
	setUserCookie(c, req, res, info);
	res.redirect(safeNext(st["x"].opt!string(null), c.basePath));
}

unittest
{
	auto c = loadAuthConfig(Json.emptyObject, parseJsonString(`{"cookie_secret":"0123456789abcdef!",
		"redirect_uri":"http://h/oauth2callback",
		"google":{"client_id":"cid","client_secret":"s","server_metadata_url":"https://x/.well-known"},
		"users":{"ann":{"password_hash":"x","name":"Ann"}}}`), "", new MemoryUserStore);
	assert(c.enabled && c.hasPasswords && c.providers.length == 1 && c.providers[0].name == "google");
	assert(c.accounts.settings.registration == Registration.off); // users configured: no sign-up by default
	import std.exception : assertThrown;
	assertThrown(loadAuthConfig(Json.emptyObject, parseJsonString(`{"users":{"a":{}},"cookie_secret":"short"}`), ""));
	assertThrown(loadAuthConfig(parseJsonString(`{"required":true,"registration":"off","cookie_secret":"0123456789abcdef!"}`),
		Json.emptyObject, ""));
	assertThrown(loadAuthConfig(parseJsonString(`{"registration":"maybe","cookie_secret":"0123456789abcdef!"}`), Json.emptyObject, ""));
	auto off = loadAuthConfig(Json.emptyObject, Json.emptyObject, "");
	assert(!off.enabled);
	// an [auth] section without users: sign-up of the first admin
	auto su = loadAuthConfig(parseJsonString(`{"required":true,"cookie_secret":"0123456789abcdef!","signup_fields":["name"]}`),
		Json.emptyObject, "/app", new MemoryUserStore);
	assert(su.enabled && su.hasPasswords && su.accounts.settings.registration == Registration.firstAdmin);
	assert(su.accounts.signupOpen && su.accounts.settings.signupFields == ["name"]);
	assertThrown(loadAuthConfig(parseJsonString(`{"cookie_secret":"0123456789abcdef!","signup_fields":["age"]}`), Json.emptyObject, ""));
	// sign-ups per address: 10 an hour by default, configurable, 0 = no limit
	assert(su.accounts.settings.signupsPerHour == 10);
	auto lim = loadAuthConfig(parseJsonString(`{"cookie_secret":"0123456789abcdef!","registration":"open","signups_per_hour":2}`),
		Json.emptyObject, "", new MemoryUserStore);
	lim.signups.fail(null, "10.0.0.1");
	assert(!lim.signups.blocked(null, "10.0.0.1"));
	lim.signups.fail(null, "10.0.0.1");
	assert(lim.signups.blocked(null, "10.0.0.1") && !lim.signups.blocked(null, "10.0.0.2"));
	auto nolim = loadAuthConfig(parseJsonString(`{"cookie_secret":"0123456789abcdef!","registration":"open","signups_per_hour":0}`),
		Json.emptyObject, "", new MemoryUserStore);
	foreach (i; 0 .. 50)
		nolim.signups.fail(null, "10.0.0.1");
	assert(!nolim.signups.blocked(null, "10.0.0.1"));
	auto payload = decodeJwtPayload("eyJhbGciOiJub25lIn0." ~ Base64URLNoPadding.encode(cast(const(ubyte)[]) `{"sub":"1"}`).idup ~ ".");
	assert(payload["sub"].get!string == "1");
}

unittest
{
	// without cookie_secret, sign-up generates one next to the user file (and reuses it)
	import std.file : tempDir, exists, rmdirRecurse, readText;
	import std.path : buildPath;
	auto dir = buildPath(tempDir, "streamlitd-secret-test");
	if (dir.exists) rmdirRecurse(dir);
	scope (exit) if (dir.exists) rmdirRecurse(dir);
	auto cfg = parseJsonString(`{"registration":"open"}`);
	cfg["users_file"] = buildPath(dir, "users.json");
	auto a = loadAuthConfig(cfg, Json.emptyObject, "", new MemoryUserStore);
	auto path = secretPathFor(buildPath(dir, "users.json"));
	assert(path.exists && a.cookieSecret.length >= 32);
	auto b = loadAuthConfig(cfg, Json.emptyObject, "", new MemoryUserStore);
	assert(a.cookieSecret == b.cookieSecret);
}

unittest
{
	// the pages over HTTP: sign-up of the first admin, CSRF and origin checks, login throttling,
	// account changes and logout everywhere
	import std.algorithm : canFind, findSplitAfter, findSplitBefore;
	import std.string : indexOf;
	import vibe.inet.url : URL;
	import vibe.inet.message : InetHeaderMap;
	import vibe.http.common : HTTPMethod;
	import vibe.stream.memory : createMemoryOutputStream, createMemoryStream;
	import streamlitd.accounts : g_hashIterations;
	g_hashIterations = 1000;
	scope (exit) g_hashIterations = defaultIterations;

	auto c = new AuthConfig;
	*c = loadAuthConfig(parseJsonString(`{"required":true,"cookie_secret":"0123456789abcdef!","rate_limit":{"max_failures":2}}`),
		Json.emptyObject, "", new MemoryUserStore);
	auto router = new URLRouter;
	registerAuthRoutes(router, c);

	string call(HTTPMethod m, string path, string cookie = null, string form = null, string origin = null)
	{
		InetHeaderMap h;
		h["Host"] = "127.0.0.1:8501";
		if (cookie.length) h["Cookie"] = cookie;
		if (origin.length) h["Origin"] = origin;
		if (form !is null) h["Content-Type"] = "application/x-www-form-urlencoded";
		auto sink = createMemoryOutputStream();
		auto req = createTestHTTPServerRequest(URL("http://127.0.0.1:8501" ~ path), m, h,
			form is null ? null : createMemoryStream(cast(ubyte[]) form.dup));
		auto res = createTestHTTPServerResponse(sink);
		router.handleRequest(req, res);
		res.finalize();
		return cast(string) sink.data.idup;
	}
	string csrf(string page)
	{
		auto i = page.indexOf(`name="csrf" value="`);
		assert(i >= 0, page);
		auto rest = page[i + 19 .. $];
		return encodeComponent(rest[0 .. rest.indexOf('"')]);
	}
	string cookieOf(string response)
	{
		auto i = response.indexOf("streamlitd_auth=");
		if (i < 0)
			return null;
		auto rest = response[i .. $];
		return rest[0 .. rest.indexOf(';')];
	}

	// the first sign-up: the page says so, the account is admin, the cookie is set
	auto reg = call(HTTPMethod.GET, "/auth/register");
	assert(reg.canFind("first-admin-note"), reg);
	assert(call(HTTPMethod.GET, "/auth/login").canFind("register-link"));
	auto form = "csrf=" ~ csrf(reg) ~ "&username=Root&name=Root&email=&password=blue+horse+7&password2=blue+horse+7&next=%2Freports";
	assert(call(HTTPMethod.POST, "/auth/register", null, "username=x&password=y&password2=y").canFind("403")); // no token
	assert(call(HTTPMethod.POST, "/auth/register", null, form, "http://evil.example").canFind("403")); // other origin
	auto r = call(HTTPMethod.POST, "/auth/register", null, form);
	assert(r.canFind("302") && r.canFind("Location: /reports"), r);
	auto rootCookie = cookieOf(r);
	assert(rootCookie.length && c.accounts.user("root").isAdmin);
	// first_admin: closed now
	assert(call(HTTPMethod.GET, "/auth/register").canFind("403"));
	assert(!call(HTTPMethod.GET, "/auth/login").canFind("register-link"));

	// login: wrong passwords are throttled (max_failures = 2), then even the right one waits
	auto login = call(HTTPMethod.GET, "/auth/login");
	auto bad = "csrf=" ~ csrf(login) ~ "&username=root&password=nope";
	assert(call(HTTPMethod.POST, "/auth/login", null, bad).canFind("401"));
	assert(call(HTTPMethod.POST, "/auth/login", null, bad).canFind("401"));
	auto good = "csrf=" ~ csrf(login) ~ "&username=root&password=blue+horse+7&next=https%3A%2F%2Fevil.example";
	assert(call(HTTPMethod.POST, "/auth/login", null, good).canFind("429"));
	c.throttle.succeed("root");
	c.throttle = new LoginThrottle; // also forget the address
	r = call(HTTPMethod.POST, "/auth/login", null, good);
	assert(r.canFind("302") && r.canFind("Location: /\r\n"), r); // a foreign `next` goes home

	// the account page: change the password; the old cookie stops working, the new one works
	auto acct = call(HTTPMethod.GET, "/auth/account", rootCookie);
	assert(acct.canFind("account-info") && acct.canFind("Change password"), acct);
	assert(call(HTTPMethod.GET, "/auth/account").canFind("Location: /auth/login?next="));
	auto pw = "csrf=" ~ csrf(acct) ~ "&action=password&current=blue+horse+7&password=red+river+99&password2=red+river+99";
	r = call(HTTPMethod.POST, "/auth/account", rootCookie, pw);
	assert(r.canFind("saved=password"), r);
	auto newCookie = cookieOf(r);
	assert(call(HTTPMethod.GET, "/auth/account", rootCookie).canFind("Location: /auth/login"));
	acct = call(HTTPMethod.GET, "/auth/account", newCookie);
	assert(acct.canFind("account-info"));
	// a token from another user's page does not work
	assert(call(HTTPMethod.POST, "/auth/account", newCookie, "csrf=" ~ csrf(login) ~ "&action=logout_all").canFind("403"));
	r = call(HTTPMethod.POST, "/auth/account", newCookie, "csrf=" ~ csrf(acct) ~ "&action=logout_all");
	assert(r.canFind("Location: /auth/login"));
	assert(call(HTTPMethod.GET, "/auth/account", newCookie).canFind("Location: /auth/login"));

	// a reset link sets a new password once
	auto link = c.accounts.createResetLink("root");
	auto page = call(HTTPMethod.GET, link);
	assert(page.canFind("Set a new password") && page.canFind(`name="token"`), page);
	auto tok = link[link.indexOf("token=") + 6 .. $];
	r = call(HTTPMethod.POST, "/auth/reset", null, "csrf=" ~ csrf(page) ~ "&token=" ~ encodeComponent(tok) ~ "&password=green+tree+42&password2=green+tree+42");
	assert(r.canFind("302") && cookieOf(r).length, r);
	assert(call(HTTPMethod.GET, link).canFind("410"));
}

unittest
{
	// behind a trusted proxy, the client address is the entry the proxy appended (the last one)
	import vibe.inet.url : URL;
	import vibe.inet.message : InetHeaderMap;
	import vibe.http.common : HTTPMethod;
	InetHeaderMap h;
	h["X-Forwarded-For"] = "6.6.6.6, 10.0.0.7";
	auto req = createTestHTTPServerRequest(URL("http://127.0.0.1:8501/auth/login"), HTTPMethod.GET, h);
	AuthConfig c;
	c.trustProxy = true;
	assert(clientIp(c, req) == "10.0.0.7");
	c.trustProxy = false;
	assert(clientIp(c, req) != "10.0.0.7" && clientIp(c, req) != "6.6.6.6");
}

unittest
{
	// a store's count() is asked once at startup, not on every request
	static class CountingStore : MemoryUserStore
	{
		size_t counted;
		override size_t count() { counted++; return super.count(); }
	}
	auto st = new CountingStore;
	StoredUser u;
	u.username = "ann";
	st.insert(u);
	auto c = loadAuthConfig(parseJsonString(`{"registration":"off","cookie_secret":"0123456789abcdef!"}`), Json.emptyObject, "", st);
	assert(c.enabled && st.counted == 1);
	foreach (_; 0 .. 5)
		assert(c.enabled);
	assert(st.counted == 1);
}
