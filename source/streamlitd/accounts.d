/// User accounts: sign-up, the user store, roles, invites, password resets and login throttling.
///
/// Passwords are always hashed here (PBKDF2, see `streamlitd.auth`); apps and admins never
/// handle hashes. Users live in a `UserStore`: by default the JSON file `.streamlitd/users.json`
/// (`[auth] users_file`), or any store the app plugs in with `useUserStore` (e.g. a database).
/// Users from `[auth.users.*]` in secrets.toml keep working, read-only.
module streamlitd.accounts;

import core.sync.mutex : Mutex;
import std.algorithm : canFind, countUntil, filter, remove, sort;
import std.array : array, split;
import std.conv : to;
import std.datetime : Clock;
import std.string : strip, toLower, indexOf;
import vibe.data.json;

import streamlitd.auth;

/// A user in the store. Password users have a `passwordHash`; users from an OIDC provider have
/// `provider` set (and `username` = `"<provider>:<sub>"`).
struct StoredUser
{
	string username;      /// lowercase; the login name (and `st.user.sub`)
	string passwordHash;  /// `pbkdf2_sha256$...`; empty for OIDC users
	string name;
	string email;
	string[] roles;       /// e.g. ["admin"], ["editor"]
	bool disabled;        /// cannot log in; existing logins end
	bool pending;         /// signed up in `approval` mode, waiting for an admin
	long created;         /// Unix time
	long lastLogin;       /// Unix time, 0 = never
	uint loginVersion = 1; /// increased by password changes and "log out everywhere"; ends older logins
	string provider;      /// null for password users, else the OIDC provider key
	Json extra;           /// free-form data for the app (kept as is)

	bool isAdmin() const { return roles.canFind("admin"); }
	/// "active", "pending" or "disabled".
	string status() const { return disabled ? "disabled" : pending ? "pending" : "active"; }
}

/// A one-time invite (only a hash of its code is stored).
struct Invite
{
	string codeHash;   /// SHA-256 of the code, hex
	string[] roles;    /// roles the new account gets
	long created;
	long expires;      /// Unix time
	string createdBy;

	/// Short id for lists and revoking (the start of the hash; not usable to sign up).
	string id() const { return codeHash.length >= 10 ? codeHash[0 .. 10] : codeHash; }
}

/// Raised for problems a user should see ("username taken", "password too short", ...).
class AccountError : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Storage for users and invites. Implementations must be thread-safe (app scripts run on
/// worker threads). Usernames are passed lowercased.
interface UserStore
{
	/// The user, or `null`.
	StoredUser* find(string username);
	/// The user with this email (case-insensitive), or `null`.
	StoredUser* findByEmail(string email);
	/// All users, ordered by `created`.
	StoredUser[] list();
	size_t count();
	/// Add a user; throws `AccountError` when the username exists.
	void insert(StoredUser u);
	/// Replace the user with the same username.
	void update(StoredUser u);
	void remove(string username);

	void putInvite(Invite inv);
	/// Remove and return the invite with this code hash, or `null` (single use).
	Invite* takeInvite(string codeHash);
	Invite[] listInvites();
	void removeInvite(string id);
}

/// A store in memory (tests, or apps that only need users until a restart).
class MemoryUserStore : UserStore
{
	protected Mutex mtx;
	protected StoredUser[] users;
	protected Invite[] invites;

	this() { mtx = new Mutex; }

	/// Called after each change (the file store saves here).
	protected void changed() {}

	StoredUser* find(string username)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		foreach (ref u; users)
			if (u.username == username)
				{ auto p = new StoredUser; *p = u; return p; }
		return null;
	}

	StoredUser* findByEmail(string email)
	{
		if (!email.length)
			return null;
		auto e = email.toLower;
		mtx.lock(); scope (exit) mtx.unlock();
		foreach (ref u; users)
			if (u.email.toLower == e)
				{ auto p = new StoredUser; *p = u; return p; }
		return null;
	}

	StoredUser[] list()
	{
		mtx.lock(); scope (exit) mtx.unlock();
		return users.dup;
	}

	size_t count()
	{
		mtx.lock(); scope (exit) mtx.unlock();
		return users.length;
	}

	void insert(StoredUser u)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		foreach (ref x; users)
			if (x.username == u.username)
				throw new AccountError("The username \"" ~ u.username ~ "\" is taken.");
		users ~= u;
		changed();
	}

	void update(StoredUser u)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		foreach (ref x; users)
			if (x.username == u.username)
			{
				x = u;
				changed();
				return;
			}
		throw new AccountError("No user \"" ~ u.username ~ "\".");
	}

	void remove(string username)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		auto i = users.countUntil!(x => x.username == username);
		if (i >= 0)
		{
			users = users.remove(i);
			changed();
		}
	}

	void putInvite(Invite inv)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		invites ~= inv;
		changed();
	}

	Invite* takeInvite(string codeHash)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		auto i = invites.countUntil!(x => x.codeHash == codeHash);
		if (i < 0)
			return null;
		auto r = new Invite; *r = invites[i];
		invites = invites.remove(i);
		changed();
		return r;
	}

	Invite[] listInvites()
	{
		mtx.lock(); scope (exit) mtx.unlock();
		return invites.dup;
	}

	void removeInvite(string id)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		auto before = invites.length;
		invites = invites.filter!(x => x.id != id).array;
		if (invites.length != before)
			changed();
	}
}

/// The default store: a JSON file, written atomically (temporary file + rename) with mode 0600.
/// It is read once at startup; a file that cannot be parsed is an error (never silently reset).
class JsonFileUserStore : MemoryUserStore
{
	immutable string path;

	this(string path)
	{
		import std.file : exists, readText;
		super();
		this.path = path;
		if (path.exists)
		{
			Json j;
			try
				j = parseJsonString(readText(path));
			catch (Exception e)
				throw new Exception("cannot read the user file " ~ path ~ ": " ~ e.msg);
			foreach (u; j["users"].opt!(Json[])(null))
				users ~= userFromJson(u);
			foreach (i; j["invites"].opt!(Json[])(null))
				invites ~= inviteFromJson(i);
		}
	}

	protected override void changed()
	{
		import std.file : mkdirRecurse, rename, write, exists;
		import std.path : dirName;
		auto j = Json.emptyObject;
		j["format"] = 1;
		auto us = Json.emptyArray;
		foreach (ref u; users)
			us.appendArrayElement(userToJson(u));
		j["users"] = us;
		auto is_ = Json.emptyArray;
		foreach (ref i; invites)
			is_.appendArrayElement(inviteToJson(i));
		j["invites"] = is_;
		auto dir = path.dirName;
		if (dir.length && !dir.exists)
			mkdirRecurse(dir);
		auto tmp = path ~ ".tmp";
		write(tmp, j.toPrettyString);
		restrictPermissions(tmp);
		rename(tmp, path);
	}
}

/// chmod 600 (owner only) where supported.
void restrictPermissions(string path)
{
	version (Posix)
	{
		import core.sys.posix.sys.stat : chmod;
		import std.string : toStringz;
		chmod(path.toStringz, octal600);
	}
}

private enum octal600 = 0x180; // 0600

/// A user as a JSON document (the format of users.json); handy for document databases.
Json userToJson(const ref StoredUser u)
{
	auto j = Json.emptyObject;
	j["username"] = u.username;
	if (u.passwordHash.length) j["passwordHash"] = u.passwordHash;
	if (u.name.length) j["name"] = u.name;
	if (u.email.length) j["email"] = u.email;
	auto r = Json.emptyArray;
	foreach (x; u.roles)
		r.appendArrayElement(Json(x));
	j["roles"] = r;
	if (u.disabled) j["disabled"] = true;
	if (u.pending) j["pending"] = true;
	j["created"] = u.created;
	j["lastLogin"] = u.lastLogin;
	j["version"] = u.loginVersion;
	if (u.provider.length) j["provider"] = u.provider;
	if (u.extra.type != Json.Type.undefined && u.extra.type != Json.Type.null_) j["extra"] = u.extra;
	return j;
}

/// ditto, back from JSON.
StoredUser userFromJson(Json j)
{
	StoredUser u;
	u.username = j["username"].get!string;
	u.passwordHash = j["passwordHash"].opt!string(null);
	u.name = j["name"].opt!string(null);
	u.email = j["email"].opt!string(null);
	foreach (r; j["roles"].opt!(Json[])(null))
		u.roles ~= r.get!string;
	u.disabled = j["disabled"].opt!bool(false);
	u.pending = j["pending"].opt!bool(false);
	u.created = j["created"].opt!long(0);
	u.lastLogin = j["lastLogin"].opt!long(0);
	u.loginVersion = cast(uint) j["version"].opt!long(1);
	u.provider = j["provider"].opt!string(null);
	u.extra = j["extra"];
	return u;
}

private Json inviteToJson(const ref Invite i)
{
	auto r = Json.emptyArray;
	foreach (x; i.roles)
		r.appendArrayElement(Json(x));
	return Json(["codeHash": Json(i.codeHash), "roles": r, "created": Json(i.created), "expires": Json(i.expires),
		"createdBy": Json(i.createdBy)]);
}

private Invite inviteFromJson(Json j)
{
	Invite i;
	i.codeHash = j["codeHash"].get!string;
	foreach (r; j["roles"].opt!(Json[])(null))
		i.roles ~= r.get!string;
	i.created = j["created"].opt!long(0);
	i.expires = j["expires"].opt!long(0);
	i.createdBy = j["createdBy"].opt!string(null);
	return i;
}

// ---------------------------------------------------------------- rules

/// Who may create an account (`[auth] registration`).
enum Registration
{
	off,         /// nobody signs up; admins and the CLI create users
	firstAdmin,  /// only the first account (it becomes admin)
	open,        /// anyone
	approval,    /// anyone, but new accounts wait for an admin's approval
	invite,      /// with a one-time invite from an admin
}

/// Parse a `registration` value ("off", "first_admin", "open", "approval", "invite").
Registration parseRegistration(string s)
{
	switch (s)
	{
		case "off": return Registration.off;
		case "first_admin": return Registration.firstAdmin;
		case "open": return Registration.open;
		case "approval": return Registration.approval;
		case "invite": return Registration.invite;
		default:
			throw new Exception(`[auth] registration must be "off", "first_admin", "open", "approval" or "invite", not "` ~ s ~ `"`);
	}
}

/// The config name of a registration mode.
string registrationName(Registration r)
{
	final switch (r)
	{
		case Registration.off: return "off";
		case Registration.firstAdmin: return "first_admin";
		case Registration.open: return "open";
		case Registration.approval: return "approval";
		case Registration.invite: return "invite";
	}
}

/// Lowercase and check a username: 3–64 characters `a-z 0-9 . _ -`, starting with a letter or digit.
string normalizeUsername(string name)
{
	auto u = name.strip.toLower;
	if (u.length < 3 || u.length > 64)
		throw new AccountError("A username needs 3 to 64 characters.");
	foreach (i, char c; u)
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (i > 0 && (c == '.' || c == '_' || c == '-'))))
			throw new AccountError("A username may contain letters, digits, '.', '_' and '-' (and must start with a letter or digit).");
	return u;
}

/// A loose email check (one "@", a dot in the domain, no spaces); returns the trimmed address.
string normalizeEmail(string email)
{
	auto e = email.strip;
	if (!e.length)
		return null;
	auto at = e.indexOf('@');
	auto dom = at > 0 ? e[at + 1 .. $] : null;
	if (at <= 0 || dom.indexOf('@') >= 0 || dom.indexOf('.') <= 0 || e.indexOf(' ') >= 0 || e.length > 254 || e[$ - 1] == '.')
		throw new AccountError("Please enter a valid email address.");
	return e;
}

private immutable string[] commonPasswords = [
	"password", "password1", "password12", "password123", "passw0rd", "12345678", "123456789", "1234567890",
	"11111111", "00000000", "qwertyui", "qwerty123", "qwertyuiop", "iloveyou", "sunshine", "princess",
	"football", "baseball", "welcome1", "welcome123", "admin123", "administrator", "letmein1", "trustno1",
	"abc12345", "abcd1234", "1q2w3e4r", "1qaz2wsx", "zaq12wsx", "changeme", "default1", "monkey123",
	"dragon123", "master123", "superman", "starwars", "whatever", "computer", "internet", "michael1",
	"qwerty12", "asdfghjk", "asdf1234", "87654321", "12341234", "123123123", "987654321", "secret123",
];

/// Maximum accepted password length (PBKDF2 cost grows with it).
enum maxPasswordLength = 1024;

/// Why `password` is not acceptable, or null.
string passwordProblem(string password, size_t minLength, string username = null, string email = null)
{
	if (password.length < minLength)
		return "The password needs at least " ~ minLength.to!string ~ " characters.";
	if (password.length > maxPasswordLength)
		return "The password is too long.";
	auto low = password.toLower;
	if ((username.length && low == username.toLower) || (email.length && low == email.toLower))
		return "The password must differ from the username and email.";
	if (commonPasswords.canFind(low))
		return "This password is too common. Please choose another one.";
	return null;
}

/// Hex SHA-256 (invite codes are stored only as this hash).
string sha256Hex(string s)
{
	import std.digest : toHexString, LetterCase;
	import std.digest.sha : sha256Of;
	return toHexString!(LetterCase.lower)(sha256Of(s)).idup;
}

/// A random URL-safe code.
string randomCode(size_t bytes = 18)
{
	import std.base64 : Base64URLNoPadding;
	return Base64URLNoPadding.encode(randomBytes(bytes)).idup;
}

/// Iterations for new hashes (tests lower it).
package __gshared uint g_hashIterations = defaultIterations;

/// Inside a vibe.d task (e.g. a request handler), PBKDF2 runs on a worker thread, so the event
/// loop keeps serving other requests while it works.
private bool inTask()
{
	import vibe.core.task : Task;
	return Task.getThis() != Task.init;
}

/// Hash a new password (PBKDF2; deliberately slow).
string hashPasswordSlow(string password)
{
	if (inTask)
	{
		import vibe.core.concurrency : async;
		auto h = async(&hashNothrow, password, g_hashIterations).getResult();
		if (h.length)
			return h;
	}
	return hashPasswordString(password, g_hashIterations);
}

/// ditto, for verifying (unknown users, i.e. an empty hash, cost the same and fail).
bool verifyPasswordSlow(string password, string hash)
{
	if (inTask)
	{
		import vibe.core.concurrency : async;
		return async(&verifyNothrow, password, hash).getResult();
	}
	return verifyNothrow(password, hash);
}

private string hashNothrow(string pw, uint iterations) nothrow
{
	try return hashPasswordString(pw, iterations);
	catch (Exception) return null;
}

private bool verifyNothrow(string pw, string hash) nothrow
{
	try
	{
		if (hash.length == 0)
		{
			// same cost for unknown users
			verifyPassword(pw, "pbkdf2_sha256$" ~ defaultIterations.to!string ~ "$c2FsdHNhbHRzYWx0c2FsdA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=");
			return false;
		}
		return verifyPassword(pw, hash);
	}
	catch (Exception)
		return false;
}

/// Iteration count of a hash (0 when unknown).
private uint hashIterations(string hash)
{
	auto p = hash.split("$");
	if (p.length != 4)
		return 0;
	try return p[1].to!uint;
	catch (Exception) return 0;
}

// ---------------------------------------------------------------- settings and the service

/// Account settings from `[auth]`.
struct AccountSettings
{
	Registration registration = Registration.off;
	string usersFile = ".streamlitd/users.json";
	string[] signupFields = ["name", "email"]; /// extra sign-up fields: "name", "email"
	bool requireEmail;
	size_t passwordMinLength = 8;
	string[] allowedEmailDomains;  /// empty = any
	string[] defaultRoles;
	string[] admins;               /// usernames or emails that are always admins (config and OIDC users)
	/// login throttling: failures per username / per IP within `throttleMinutes`
	uint maxFailures = 5;
	uint maxIpFailures = 20;
	uint throttleMinutes = 15;
}

/// Outcome of a password check.
enum LoginResult { ok, invalid, pending, disabled }

/// The account service: one per server (`accounts()`), shared by the login pages, the CLI and
/// the app (`st.accounts`). Thread-safe through the store.
final class Accounts
{
	AccountSettings settings;
	UserStore store;
	/// `[auth.users.*]` from secrets.toml (read-only users).
	Json configUsers;
	/// Signs reset links (the cookie secret).
	immutable(ubyte)[] secret;
	/// The app's base path ("" or "/app"), for links.
	string basePath;

	this(AccountSettings s, UserStore store, Json configUsers, immutable(ubyte)[] secret, string basePath = "")
	{
		settings = s;
		this.store = store;
		this.configUsers = configUsers.type == Json.Type.object ? configUsers : Json.emptyObject;
		this.secret = secret;
		this.basePath = basePath;
	}

	private static long now() { return Clock.currTime.toUnixTime; }

	/// The key of `[auth.users.<name>]` matching `username` without regard to case (usernames are
	/// not case sensitive), or null.
	string configUserKey(string username) const
	{
		auto cu = cast() configUsers; // read only: `in` and existing keys, never opIndex on a missing key
		if (auto p = username in cu)
			if (p.type == Json.Type.object)
				return username;
		auto low = username.toLower;
		foreach (string k, v; cu)
			if (k.toLower == low && v.type == Json.Type.object)
				return k;
		return null;
	}

	/// The `[auth.users.<name>]` table, or `Json.undefined`.
	Json configUser(string username) const
	{
		auto k = configUserKey(username);
		return k is null ? Json.undefined : (cast() configUsers)[k];
	}

	/// A user from `[auth.users.*]` (read-only)?
	bool isConfigUser(string username) const
	{
		return configUser(username).type == Json.Type.object;
	}

	/// Roles of a config user: its `roles`, plus "admin" when listed in `admins`.
	string[] configRoles(string username, string email = null) const
	{
		string[] r;
		auto u = configUser(username);
		if (u.type == Json.Type.object)
			foreach (x; u["roles"].opt!(Json[])(null))
				r ~= x.get!string;
		if (isListedAdmin(username, email) && !r.canFind("admin"))
			r ~= "admin";
		return r;
	}

	/// Listed in `[auth] admins` (by username or email)?
	bool isListedAdmin(string username, string email) const
	{
		foreach (a; settings.admins)
		{
			auto l = a.toLower;
			if ((username.length && l == username.toLower) || (email.length && l == email.toLower))
				return true;
		}
		return false;
	}

	/// Has this store user admin rights (the `admin` role, or listed in `admins`)?
	bool isEffectiveAdmin(const ref StoredUser u) const
	{
		return u.isAdmin || isListedAdmin(u.provider.length ? null : u.username, u.email);
	}

	/// Is there an active admin (store, config users or the `admins` list)?
	bool hasAdmin()
	{
		foreach (u; store.list)
			if (isEffectiveAdmin(u) && !u.disabled && !u.pending)
				return true;
		foreach (string name, u; configUsers)
			if (configRoles(name, u["email"].opt!string(null)).canFind("admin"))
				return true;
		return false;
	}

	/// Can somebody create a password account right now (from the sign-up page)?
	bool signupOpen()
	{
		final switch (settings.registration)
		{
			case Registration.off: return false;
			case Registration.firstAdmin: return !hasAdmin;
			case Registration.open:
			case Registration.approval:
			case Registration.invite: return true;
		}
	}

	/// Does the sign-up page need an invite code?
	bool inviteRequired() { return settings.registration == Registration.invite && hasAdmin; }

	private void checkDomain(string email)
	{
		if (!settings.allowedEmailDomains.length)
			return;
		if (!email.length)
			throw new AccountError("An email address from " ~ domainList ~ " is required.");
		auto dom = email[email.indexOf('@') + 1 .. $].toLower;
		foreach (d; settings.allowedEmailDomains)
			if (dom == d.toLower)
				return;
		throw new AccountError("Sign-up is limited to email addresses from " ~ domainList ~ ".");
	}

	private string domainList()
	{
		import std.array : join;
		return settings.allowedEmailDomains.join(", ");
	}

	private void checkNewUser(string username, string email)
	{
		if (isConfigUser(username) || store.find(username) !is null)
			throw new AccountError("The username \"" ~ username ~ "\" is taken.");
		if (email.length && store.findByEmail(email) !is null)
			throw new AccountError("An account with this email address exists.");
	}

	private void checkPassword(string password, string username, string email)
	{
		if (auto p = passwordProblem(password, settings.passwordMinLength, username, email))
			throw new AccountError(p);
	}

	private enum closedMessage = "Sign-up is closed. Please ask an administrator for an account.";

	/// Self sign-up (the registration page). Applies the registration mode: the first account
	/// becomes admin (unless `admins` names the admins; then those users need no invite or
	/// approval), `approval` accounts start pending, `invite` needs a valid `inviteCode`.
	/// Throws `AccountError` with a message for the user.
	StoredUser register(string username, string password, string name = null, string email = null,
		string inviteCode = null)
	{
		if (!signupOpen)
			throw new AccountError(closedMessage);
		username = normalizeUsername(username);
		email = normalizeEmail(email);
		if (settings.requireEmail && !email.length)
			throw new AccountError("Please enter your email address.");
		checkDomain(email);
		checkNewUser(username, email);
		checkPassword(password, username, email);
		auto hash = hashPasswordSlow(password); // slow: before the lock
		// the checks and the insert are atomic, so two simultaneous first sign-ups cannot both be admin
		synchronized (this)
		{
			if (!signupOpen)
				throw new AccountError(closedMessage);
			checkNewUser(username, email);
			immutable listed = isListedAdmin(username, email);
			if (settings.registration == Registration.firstAdmin && settings.admins.length && !listed)
				throw new AccountError(closedMessage); // waiting for the admins named in [auth] admins
			immutable autoAdmin = !hasAdmin && settings.admins.length == 0;
			immutable exempt = autoAdmin || listed; // no invite or approval needed
			string[] roles = settings.defaultRoles.dup;
			if (settings.registration == Registration.invite && !exempt)
			{
				auto inv = inviteCode.length ? store.takeInvite(sha256Hex(inviteCode.strip)) : null;
				if (inv is null || inv.expires < now)
					throw new AccountError("This invite is not valid (it may have been used or expired).");
				foreach (r; inv.roles)
					if (!roles.canFind(r))
						roles ~= r;
			}
			if (autoAdmin && !roles.canFind("admin"))
				roles ~= "admin";
			StoredUser u;
			u.username = username;
			u.passwordHash = hash;
			u.name = name.strip.length ? name.strip : null;
			u.email = email;
			u.roles = roles;
			u.pending = !exempt && settings.registration == Registration.approval;
			u.created = now;
			store.insert(u);
			return u;
		}
	}

	/// Create a user (admins, the CLI, app code); no registration-mode checks.
	StoredUser createUser(string username, string password, string name = null, string email = null,
		string[] roles = null)
	{
		username = normalizeUsername(username);
		email = normalizeEmail(email);
		checkNewUser(username, email);
		checkPassword(password, username, email);
		StoredUser u;
		u.username = username;
		u.passwordHash = hashPasswordSlow(password);
		u.name = name.strip.length ? name.strip : null;
		u.email = email;
		u.roles = roles.dup;
		u.created = now;
		synchronized (this)
		{
			checkNewUser(username, email);
			store.insert(u);
		}
		return u;
	}

	/// Check a username and password (store and config users). `user` receives the session claims
	/// on success. Unknown users cost the same time as wrong passwords.
	LoginResult checkLogin(string username, string password, out Json user)
	{
		auto name = username.strip.toLower;
		if (password.length > maxPasswordLength)
			password = password[0 .. maxPasswordLength];
		// config users first (they shadow store users of the same name); `sub` keeps their spelling
		auto key = configUserKey(username.strip);
		auto cu = key is null ? Json.undefined : configUser(key);
		if (cu.type == Json.Type.object)
		{
			if (!verifyPasswordSlow(password, cu["password_hash"].opt!string("")))
				return LoginResult.invalid;
			auto email = cu["email"].opt!string(null);
			user = Json(["sub": Json(key), "name": Json(cu["name"].opt!string(key)), "email": Json(email),
				"provider": Json("password")]);
			return LoginResult.ok;
		}
		auto u = name.length ? store.find(name) : null;
		auto hash = u !is null && u.provider.length == 0 ? u.passwordHash : "";
		if (!verifyPasswordSlow(password, hash) || hash.length == 0)
			return LoginResult.invalid;
		if (u.disabled)
			return LoginResult.disabled;
		if (u.pending)
			return LoginResult.pending;
		u.lastLogin = now;
		if (hashIterations(u.passwordHash) < g_hashIterations)
			u.passwordHash = hashPasswordSlow(password); // upgrade old hashes
		store.update(*u);
		user = claimsOf(*u);
		return LoginResult.ok;
	}

	/// Session claims of a store user (stored in the login cookie).
	Json claimsOf(const ref StoredUser u)
	{
		auto j = Json.emptyObject;
		j["sub"] = u.provider.length ? u.username[u.provider.length + 1 .. $] : u.username;
		j["name"] = u.name.length ? u.name : u.provider.length ? u.email : u.username;
		j["email"] = u.email.length ? Json(u.email) : Json(null);
		j["provider"] = u.provider.length ? u.provider : "password";
		j["store"] = true;     // checked against the store on each request
		j["v"] = u.loginVersion;
		return j;
	}

	/// Validate cookie claims against the store and add fresh roles: returns the user, or
	/// `Json(null)` when the account was deleted, disabled, is pending or its logins were ended.
	Json resolve(Json claims)
	{
		if (claims.type != Json.Type.object)
			return Json(null);
		auto provider = claims["provider"].opt!string("password");
		auto sub = claims["sub"].opt!string(null);
		if (claims["store"].opt!bool(false))
		{
			auto key = provider == "password" ? sub : provider ~ ":" ~ sub;
			auto u = store.find(key);
			if (u is null || u.disabled || u.pending || u.loginVersion != cast(uint) claims["v"].opt!long(0))
				return Json(null);
			auto r = claims.clone;
			r["name"] = u.name.length ? Json(u.name) : claims["name"];
			r["email"] = u.email.length ? Json(u.email) : claims["email"];
			r["roles"] = rolesJson(withListedAdmin(u.roles, provider == "password" ? sub : null, u.email));
			r["username"] = u.username;
			return r;
		}
		// config users and (older) OIDC logins that are not in the store
		auto r = claims.clone;
		string[] roles = provider == "password" ? configRoles(sub, claims["email"].opt!string(null))
			: withListedAdmin(null, null, claims["email"].opt!string(null));
		r["roles"] = rolesJson(roles);
		if (provider == "password")
			r["username"] = sub;
		return r;
	}

	private string[] withListedAdmin(string[] roles, string username, string email)
	{
		auto r = roles.dup;
		if (isListedAdmin(username, email) && !r.canFind("admin"))
			r ~= "admin";
		return r;
	}

	private static Json rolesJson(string[] roles)
	{
		auto a = Json.emptyArray;
		foreach (r; roles)
			a.appendArrayElement(Json(r));
		return a;
	}

	/// An OIDC sign-in: records the user in the store on first sign-in (so admins can give roles
	/// or disable them), applies `allowed_email_domains`, `approval` and `invite`. Returns the
	/// session claims; throws `AccountError` when the user may not sign in.
	Json oidcSignIn(string provider, string sub, string name, string email, string picture, string inviteCode = null)
	{
		auto key = provider ~ ":" ~ sub;
		email = email.strip;
		auto u = store.find(key);
		if (u is null) synchronized (this) // atomic, like `register`
		{
			u = store.find(key); // another request may have added it meanwhile
			if (u is null)
			{
				if (settings.allowedEmailDomains.length)
					checkDomain(email);
				immutable autoAdmin = !hasAdmin && settings.admins.length == 0;
				immutable exempt = autoAdmin || isListedAdmin(null, email);
				string[] roles = settings.defaultRoles.dup;
				bool pending;
				if (settings.registration == Registration.invite && !exempt)
				{
					auto inv = inviteCode.length ? store.takeInvite(sha256Hex(inviteCode.strip)) : null;
					if (inv is null || inv.expires < now)
						throw new AccountError("You need an invite to sign up. Please ask an administrator.");
					foreach (r; inv.roles)
						if (!roles.canFind(r))
							roles ~= r;
				}
				else if (settings.registration == Registration.approval && !exempt)
					pending = true;
				if (autoAdmin && settings.registration != Registration.off && !roles.canFind("admin"))
					roles ~= "admin";
				StoredUser n;
				n.username = key;
				n.name = name;
				n.email = email.length ? email : null;
				n.roles = roles;
				n.pending = pending;
				n.created = now;
				n.provider = provider;
				store.insert(n);
				u = store.find(key);
			}
		}
		if (u.disabled)
			throw new AccountError("This account is disabled.");
		if (u.pending)
			throw new AccountError("Your account is waiting for an administrator's approval.");
		u.lastLogin = now;
		if (name.length) u.name = name;
		if (email.length) u.email = email;
		store.update(*u);
		auto c = claimsOf(*u);
		c["picture"] = picture.length ? Json(picture) : Json(null);
		return c;
	}

	// ------------------------------------------------ changes by the user

	/// Change one's own password (needs the current one). Ends other logins; returns the new claims.
	Json changePassword(string username, string current, string newPassword)
	{
		auto u = mustFind(username);
		if (u.provider.length || !verifyPasswordSlow(current, u.passwordHash))
			throw new AccountError("The current password is not correct.");
		checkPassword(newPassword, u.username, u.email);
		u.passwordHash = hashPasswordSlow(newPassword);
		u.loginVersion++;
		store.update(*u);
		return claimsOf(*u);
	}

	/// Change name and email.
	void updateProfile(string username, string name, string email)
	{
		auto u = mustFind(username);
		email = normalizeEmail(email);
		if (settings.requireEmail && !email.length && !u.provider.length)
			throw new AccountError("Please enter your email address.");
		if (email.length && email.toLower != u.email.toLower)
		{
			checkDomain(email);
			if (store.findByEmail(email) !is null)
				throw new AccountError("An account with this email address exists.");
		}
		u.name = name.strip.length ? name.strip : null;
		u.email = email;
		store.update(*u);
	}

	// ------------------------------------------------ admin actions

	private StoredUser* mustFind(string username)
	{
		auto u = store.find(username.strip.toLower);
		if (u is null)
			u = store.find(username.strip);
		if (u is null)
			throw new AccountError("No user \"" ~ username ~ "\".");
		return u;
	}

	/// The store user, or `null`.
	StoredUser* user(string username)
	{
		auto u = store.find(username.strip.toLower);
		return u !is null ? u : store.find(username.strip);
	}

	/// All store users.
	StoredUser[] users() { return store.list; }

	/// Number of active admins in the store.
	private size_t storeAdmins()
	{
		size_t n;
		foreach (u; store.list)
			if (isEffectiveAdmin(u) && !u.disabled && !u.pending)
				n++;
		return n;
	}

	/// Would this change leave the app without an admin (when the store has the only admins)?
	private void keepAnAdmin(const ref StoredUser before, bool stillAdmin)
	{
		if (!isEffectiveAdmin(before) || before.disabled || before.pending || stillAdmin)
			return;
		bool configAdmin;
		foreach (string name, u; configUsers)
			if (configRoles(name, u["email"].opt!string(null)).canFind("admin"))
				configAdmin = true;
		if (!configAdmin && storeAdmins <= 1)
			throw new AccountError("This is the last administrator; make someone else admin first.");
	}

	/// Set a new password (admin or CLI); ends the user's logins.
	void setPassword(string username, string newPassword)
	{
		auto u = mustFind(username);
		if (u.provider.length)
			throw new AccountError("\"" ~ u.username ~ "\" signs in with " ~ u.provider ~ " and has no password here.");
		checkPassword(newPassword, u.username, u.email);
		u.passwordHash = hashPasswordSlow(newPassword);
		u.loginVersion++;
		store.update(*u);
	}

	/// Replace the roles.
	void setRoles(string username, string[] roles)
	{
		auto u = mustFind(username);
		// listed in `admins`: still admin without the role
		keepAnAdmin(*u, roles.canFind("admin") || isListedAdmin(u.provider.length ? null : u.username, u.email));
		u.roles = roles.dup;
		store.update(*u);
	}

	/// Disable (logins end) or enable an account.
	void setDisabled(string username, bool disabled)
	{
		auto u = mustFind(username);
		if (disabled)
			keepAnAdmin(*u, false);
		u.disabled = disabled;
		store.update(*u);
	}

	/// Approve a pending account.
	void approve(string username)
	{
		auto u = mustFind(username);
		u.pending = false;
		store.update(*u);
	}

	/// End all logins of the user (on every device).
	void logoutEverywhere(string username)
	{
		auto u = mustFind(username);
		u.loginVersion++;
		store.update(*u);
	}

	/// Delete an account.
	void deleteUser(string username)
	{
		auto u = mustFind(username);
		keepAnAdmin(*u, false);
		store.remove(u.username);
	}

	/// Create a one-time invite valid for `days` days; returns the code (shown once; only its hash
	/// is stored). The sign-up link is `inviteLink(code)`.
	string createInvite(string[] roles = null, uint days = 7, string createdBy = null)
	{
		auto code = randomCode(12);
		Invite i;
		i.codeHash = sha256Hex(code);
		i.roles = roles.dup;
		i.created = now;
		i.expires = now + days * 86_400L;
		i.createdBy = createdBy;
		store.putInvite(i);
		return code;
	}

	/// Open invites (expired ones are removed).
	Invite[] invites()
	{
		foreach (i; store.listInvites)
			if (i.expires < now)
				store.removeInvite(i.id);
		return store.listInvites;
	}

	/// Revoke an invite by its `id`.
	void revokeInvite(string id) { store.removeInvite(id); }

	/// The sign-up link for an invite code (a path under the app's base; prefix your host).
	string inviteLink(string code) { return basePath ~ "/auth/register?invite=" ~ code; }

	/// A one-time link to set a new password, valid for `hours` (a path under the app's base).
	/// It stops working once the password changes.
	string createResetLink(string username, uint hours = 24)
	{
		auto u = mustFind(username);
		if (u.provider.length)
			throw new AccountError("\"" ~ u.username ~ "\" signs in with " ~ u.provider ~ " and has no password here.");
		if (secret.length < 16)
			throw new AccountError("Reset links need a cookie secret ([auth] cookie_secret).");
		auto tok = signValue(Json(["r": Json(u.username), "v": Json(u.loginVersion), "exp": Json(now + hours * 3600L)]).toString, secret);
		return basePath ~ "/auth/reset?token=" ~ tok;
	}

	/// The user a reset token is for, or null when it is invalid, expired or used.
	string resetTokenUser(string token)
	{
		auto p = verifySigned(token, secret);
		if (p is null)
			return null;
		try
		{
			auto j = parseJsonString(p);
			if (j["exp"].get!long < now)
				return null;
			auto u = store.find(j["r"].get!string);
			if (u is null || u.disabled || u.loginVersion != cast(uint) j["v"].get!long)
				return null;
			return u.username;
		}
		catch (Exception)
			return null;
	}

	/// Set a new password with a reset token; returns the session claims.
	Json resetPassword(string token, string newPassword)
	{
		auto name = resetTokenUser(token);
		if (name is null)
			throw new AccountError("This link is not valid any more. Please ask an administrator for a new one.");
		setPassword(name, newPassword);
		return claimsOf(*store.find(name)); // a pending account stays pending
	}
}

// ---------------------------------------------------------------- the server's instance

private __gshared Accounts g_accounts;
private __gshared UserStore g_customStore;

/// Use your own user store (e.g. a database) instead of `.streamlitd/users.json`. Call before
/// `serve` / in `main`.
void useUserStore(UserStore store) { g_customStore = store; }

/// The store set with `useUserStore`, or null.
package UserStore customUserStore() { return g_customStore; }

/// The server's account service (`null` when `[auth]` is not configured).
Accounts accounts() { return g_accounts; }

package void setAccounts(Accounts a) { g_accounts = a; }

// ---------------------------------------------------------------- login throttling

/// Counts failed logins per username and per client address and blocks further attempts for a
/// while (in memory; a restart clears it).
final class LoginThrottle
{
	private Mutex mtx;
	private long[][string] byUser, byIp;
	uint maxUser, maxIp, windowSeconds;
	long delegate() clock;

	this(uint maxUser = 5, uint maxIp = 20, uint windowMinutes = 15)
	{
		mtx = new Mutex;
		this.maxUser = maxUser;
		this.maxIp = maxIp;
		this.windowSeconds = windowMinutes * 60;
		clock = () => Clock.currTime.toUnixTime;
	}

	private size_t recent(ref long[][string] m, string k, long t)
	{
		auto p = k in m;
		if (p is null)
			return 0;
		*p = (*p).filter!(x => x > t - windowSeconds).array;
		if (!(*p).length)
		{
			m.remove(k);
			return 0;
		}
		return (*p).length;
	}

	/// Too many recent failures for this username or address?
	bool blocked(string user, string ip)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		auto t = clock();
		return (user.length && maxUser && recent(byUser, user.toLower, t) >= maxUser)
			|| (ip.length && maxIp && recent(byIp, ip, t) >= maxIp);
	}

	/// Record a failure.
	void fail(string user, string ip)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		auto t = clock();
		if (user.length)
			byUser[user.toLower] ~= t;
		if (ip.length)
			byIp[ip] ~= t;
	}

	/// A successful login clears the username's failures.
	void succeed(string user)
	{
		mtx.lock(); scope (exit) mtx.unlock();
		byUser.remove(user.toLower);
	}
}

/// A safe `next` target after login: a path under the app (`base` + "/..."), never another site.
string safeNext(string next, string base)
{
	auto root = base ~ "/";
	if (!next.length || next[0] != '/' || (next.length > 1 && (next[1] == '/' || next[1] == '\\')))
		return root;
	if (next.indexOf("://") >= 0 || next.indexOf('\\') >= 0 || next.indexOf('\n') >= 0 || next.indexOf('\r') >= 0)
		return root;
	if (base.length && next != base && !(next.length > base.length && next[0 .. base.length] == base && next[base.length] == '/'))
		return root;
	import std.algorithm : startsWith;
	if (next[base.length .. $].startsWith("/auth/"))
		return root;
	return next;
}

unittest
{
	import std.exception : assertThrown;
	// usernames, emails, passwords
	assert(normalizeUsername("  Alice ") == "alice");
	assertThrown!AccountError(normalizeUsername("al"));
	assertThrown!AccountError(normalizeUsername("-bob"));
	assertThrown!AccountError(normalizeUsername("bob smith"));
	assert(normalizeEmail(" a@b.co ") == "a@b.co" && normalizeEmail("") is null);
	assertThrown!AccountError(normalizeEmail("a@b"));
	assertThrown!AccountError(normalizeEmail("a@@b.co"));
	assert(passwordProblem("short", 8) !is null);
	assert(passwordProblem("password123", 8) !is null);
	assert(passwordProblem("alice-alice", 8, "Alice-Alice") !is null);
	assert(passwordProblem("blue horse 7", 8, "alice") is null);

	// next targets
	assert(safeNext("/reports?x=1", "") == "/reports?x=1");
	assert(safeNext("//evil.com", "") == "/");
	assert(safeNext("https://evil.com", "") == "/");
	assert(safeNext("/other/x", "/app") == "/app/");
	assert(safeNext("/app/docs", "/app") == "/app/docs");
	assert(safeNext("/app/auth/logout", "/app") == "/app/");
	assert(safeNext("/\\evil", "") == "/");

	// throttle
	long t = 1000;
	auto th = new LoginThrottle(3, 5, 1);
	th.clock = () => t;
	foreach (_; 0 .. 3)
		th.fail("Bob", "1.2.3.4");
	assert(th.blocked("bob", "9.9.9.9") && !th.blocked("ann", "9.9.9.9"));
	th.fail("x", "1.2.3.4"); th.fail("y", "1.2.3.4");
	assert(th.blocked("ann", "1.2.3.4"));
	t += 61;
	assert(!th.blocked("bob", "1.2.3.4"));
	th.fail("bob", null);
	th.succeed("bob");
	assert(!th.blocked("bob", null));
}

unittest
{
	import std.exception : assertThrown;
	AccountSettings s;
	s.registration = Registration.firstAdmin;
	auto secret = cast(immutable(ubyte)[]) "0123456789abcdef!";
	g_hashIterations = 1000; // fast hashes in tests
	scope (exit) g_hashIterations = defaultIterations;
	auto a = new Accounts(s, new MemoryUserStore, Json.emptyObject, secret);
	assert(a.signupOpen && !a.hasAdmin);
	auto admin = a.register("Root", "blue horse 7", "Root User", "root@example.com");
	assert(admin.username == "root" && admin.isAdmin && admin.passwordHash.length);
	assert(!a.signupOpen); // first_admin: closed after the first account
	assertThrown!AccountError(a.register("eve", "blue horse 7"));

	Json c, tmp; // `out`: a failed check clears its argument
	assert(a.checkLogin("ROOT", "blue horse 7", c) == LoginResult.ok && c["sub"].get!string == "root");
	assert(a.checkLogin("root", "wrong", tmp) == LoginResult.invalid);
	assert(a.checkLogin("nobody", "wrong", tmp) == LoginResult.invalid);
	auto r = a.resolve(c);
	assert(r["roles"][0].get!string == "admin" && r["username"].get!string == "root");

	// admin creates a user; disable/version end logins
	a.createUser("bob", "green tree 42", "Bob", null, ["editor"]);
	Json bc;
	assert(a.checkLogin("bob", "green tree 42", bc) == LoginResult.ok);
	assert(a.resolve(bc)["roles"][0].get!string == "editor");
	a.logoutEverywhere("bob");
	assert(a.resolve(bc).type == Json.Type.null_);
	assert(a.checkLogin("bob", "green tree 42", bc) == LoginResult.ok);
	a.setDisabled("bob", true);
	assert(a.resolve(bc).type == Json.Type.null_);
	assert(a.checkLogin("bob", "green tree 42", tmp) == LoginResult.disabled);
	a.setDisabled("bob", false);

	// the last admin stays
	assertThrown!AccountError(a.setRoles("root", ["editor"]));
	assertThrown!AccountError(a.deleteUser("root"));
	assertThrown!AccountError(a.setDisabled("root", true));
	a.setRoles("bob", ["admin"]);
	a.setRoles("root", null); // fine now: bob is admin
	a.setRoles("root", ["admin"]);

	// own password change and reset links (single use)
	auto nc = a.changePassword("bob", "green tree 42", "red river 99");
	assert(a.resolve(bc).type == Json.Type.null_ && a.resolve(nc).type == Json.Type.object);
	assertThrown!AccountError(a.changePassword("bob", "wrong", "red river 100"));
	auto link = a.createResetLink("bob");
	auto tok = link[link.indexOf("token=") + 6 .. $];
	assert(a.resetTokenUser(tok) == "bob");
	a.resetPassword(tok, "yellow sun 11");
	assert(a.resetTokenUser(tok) is null);
	assertThrown!AccountError(a.resetPassword(tok, "yellow sun 12"));

	// approval mode: pending until approved
	a.settings.registration = Registration.approval;
	auto p = a.register("carol", "purple sky 5");
	assert(p.pending && !p.isAdmin);
	assert(a.checkLogin("carol", "purple sky 5", c) == LoginResult.pending);
	a.approve("carol");
	assert(a.checkLogin("carol", "purple sky 5", c) == LoginResult.ok);

	// invite mode: single-use codes with roles
	a.settings.registration = Registration.invite;
	assert(a.inviteRequired);
	assertThrown!AccountError(a.register("dave", "orange cat 3"));
	auto code = a.createInvite(["viewer"], 1, "root");
	assert(a.invites.length == 1);
	auto d = a.register("dave", "orange cat 3", null, null, code);
	assert(d.roles == ["viewer"]);
	assertThrown!AccountError(a.register("erin", "orange cat 4", null, null, code));
	auto c2 = a.createInvite();
	a.revokeInvite(a.invites[0].id);
	assertThrown!AccountError(a.register("erin", "orange cat 4", null, null, c2));

	// duplicates and email domains
	a.settings.registration = Registration.open;
	assertThrown!AccountError(a.register("Dave", "orange cat 5"));
	assertThrown!AccountError(a.register("frank", "orange cat 5", null, "ROOT@example.com"));
	a.settings.allowedEmailDomains = ["corp.com"];
	assertThrown!AccountError(a.register("frank", "orange cat 5", null, "f@gmail.com"));
	a.register("frank", "orange cat 5", null, "f@corp.com");

	// OIDC users are recorded; invite mode needs an invite for new ones
	a.settings.allowedEmailDomains = null;
	auto oc = a.oidcSignIn("google", "123", "Gina", "gina@x.com", "https://pic");
	assert(oc["provider"].get!string == "google" && oc["sub"].get!string == "123" && oc["store"].get!bool);
	assert(a.resolve(oc)["name"].get!string == "Gina");
	a.setDisabled("google:123", true);
	assert(a.resolve(oc).type == Json.Type.null_);
	assertThrown!AccountError(a.oidcSignIn("google", "123", "Gina", "gina@x.com", null));
	a.settings.registration = Registration.invite;
	assertThrown!AccountError(a.oidcSignIn("google", "456", "Hal", "hal@x.com", null));
	a.oidcSignIn("google", "456", "Hal", "hal@x.com", null, a.createInvite(["viewer"]));
}

unittest
{
	// config users: read-only, roles and the admins list
	AccountSettings s;
	s.admins = ["boss@example.com"];
	auto cfg = parseJsonString(`{"ann": {"password_hash": "` ~ hashPasswordString("blue horse 7", 1000) ~
		`", "email": "boss@example.com"}, "ben": {"password_hash": "x", "roles": ["editor"]}}`);
	auto a = new Accounts(s, new MemoryUserStore, cfg, cast(immutable(ubyte)[]) "0123456789abcdef!");
	assert(a.hasAdmin);
	Json c;
	assert(a.checkLogin("ann", "blue horse 7", c) == LoginResult.ok);
	auto r = a.resolve(c);
	assert(r["roles"][0].get!string == "admin" && r["username"].get!string == "ann");
	assert(a.resolve(Json(["sub": Json("ben"), "provider": Json("password")]))["roles"][0].get!string == "editor");
	import std.exception : assertThrown;
	s.registration = Registration.open;
	a.settings = s;
	assertThrown!AccountError(a.register("ann", "green tree 42")); // config names are taken
}

unittest
{
	// the file store: atomic writes and reload
	import std.file : tempDir, exists, remove, write;
	import std.path : buildPath;
	auto path = buildPath(tempDir, "streamlitd-users-test.json");
	if (path.exists) remove(path);
	scope (exit) if (path.exists) remove(path);
	auto st = new JsonFileUserStore(path);
	StoredUser u;
	u.username = "ann";
	u.roles = ["admin"];
	u.extra = Json(["team": Json("blue")]);
	st.insert(u);
	Invite i;
	i.codeHash = sha256Hex("code");
	i.expires = 99;
	st.putInvite(i);
	auto again = new JsonFileUserStore(path);
	assert(again.count == 1 && again.find("ann").roles == ["admin"] && again.find("ann").extra["team"].get!string == "blue");
	assert(again.takeInvite(sha256Hex("code")) !is null && again.listInvites.length == 0);
	write(path, "{broken");
	import std.exception : assertThrown;
	assertThrown(new JsonFileUserStore(path));
}

unittest
{
	import std.exception : assertThrown;
	g_hashIterations = 1000;
	scope (exit) g_hashIterations = defaultIterations;
	auto secret = cast(immutable(ubyte)[]) "0123456789abcdef!";
	// with `admins`, nobody becomes admin automatically; listed users need no invite or approval
	AccountSettings s;
	s.registration = Registration.open;
	s.admins = ["boss"];
	auto a = new Accounts(s, new MemoryUserStore, Json.emptyObject, secret);
	auto first = a.register("stranger", "blue horse 7");
	assert(!first.isAdmin && !a.hasAdmin);
	a.settings.registration = Registration.invite;
	assertThrown!AccountError(a.register("other", "blue horse 7")); // needs an invite
	auto boss = a.register("boss", "blue horse 7");                 // listed: no invite needed
	assert(!boss.isAdmin && a.isEffectiveAdmin(boss) && a.hasAdmin);
	Json c;
	assert(a.checkLogin("boss", "blue horse 7", c) == LoginResult.ok && a.resolve(c)["roles"][0].get!string == "admin");
	assertThrown!AccountError(a.setDisabled("boss", true)); // the only (listed) admin
	a.setRoles("boss", ["editor"]);                         // still admin through the list
	// first_admin with `admins`: only the listed users may sign up
	a.settings.registration = Registration.firstAdmin;
	auto b = new Accounts(a.settings, new MemoryUserStore, Json.emptyObject, secret);
	assertThrown!AccountError(b.register("stranger", "blue horse 7"));
	b.register("boss", "blue horse 7");
	assert(!b.signupOpen);
	// SSO with `admins`: the first sign-in is not admin
	a.settings.registration = Registration.open;
	auto oc = a.oidcSignIn("sso", "1", "Zed", "zed@x.com", null);
	assert(a.resolve(oc)["roles"].length == 0);

	// config usernames are not case sensitive
	auto cfg = parseJsonString(`{"Alice": {"password_hash": "` ~ hashPasswordString("green tree 42", 1000) ~ `"}}`);
	AccountSettings o;
	o.registration = Registration.open;
	auto ca = new Accounts(o, new MemoryUserStore, cfg, secret);
	assertThrown!AccountError(ca.register("alice", "blue horse 7"));
	assert(ca.checkLogin("ALICE", "green tree 42", c) == LoginResult.ok && c["sub"].get!string == "Alice");

	// a reset link does not approve a pending account
	o.registration = Registration.approval;
	auto ap = new Accounts(o, new MemoryUserStore, Json.emptyObject, secret);
	ap.register("root", "blue horse 7");
	assert(ap.register("pat", "blue horse 7").pending);
	auto link = ap.createResetLink("pat");
	ap.resetPassword(link[link.indexOf("token=") + 6 .. $], "green tree 42");
	assert(ap.user("pat").pending);
	assert(ap.checkLogin("pat", "green tree 42", c) == LoginResult.pending);
}
