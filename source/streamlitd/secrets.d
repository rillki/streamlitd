/// `st.secrets` — values from `.streamlitd/secrets.toml` (or `.streamlit/secrets.toml`).
/// Secrets stay on the server; they are never sent to the browser.
module streamlitd.secrets;

import core.sync.mutex : Mutex;
import std.array : split;
import std.path : buildPath, expandTilde;
import vibe.data.json;

import streamlitd.errors : StreamlitAPIException;
import streamlitd.toml;

/// Read-only access to secrets.
final class Secrets
{
	private Json root;

	this(Json root) { this.root = root.type == Json.Type.object ? root : Json.emptyObject; }

	/// `st.secrets["db"]["password"]`. Throws if the key is missing.
	Json opIndex(string key)
	{
		auto v = root[key];
		if (v.type == Json.Type.undefined)
			throw new StreamlitAPIException(`st.secrets has no key "` ~ key ~ `". Add it to .streamlitd/secrets.toml.`);
		return v;
	}

	/// Typed read with a dotted path, e.g. `get!string("db.password")`.
	T get(T)(string path, T def = T.init)
	{
		auto v = lookup(path);
		if (v.type == Json.Type.undefined || v.type == Json.Type.null_)
			return def;
		static if (is(T == Json))
			return v;
		else
			return v.to!T;
	}

	/// True if the dotted path exists.
	bool has(string path) { return lookup(path).type != Json.Type.undefined; }

	/// `"key" in st.secrets`
	bool opBinaryRight(string op : "in")(string key) { return has(key); }

	/// Top-level keys.
	string[] keys()
	{
		string[] r;
		foreach (string k, _; root)
			r ~= k;
		return r;
	}

	private Json lookup(string path)
	{
		Json cur = root;
		foreach (part; path.split("."))
		{
			if (cur.type != Json.Type.object)
				return Json.undefined;
			cur = cur[part];
		}
		return cur;
	}

	/// Merge `other` on top (deep, for tables).
	package void merge(Json other)
	{
		root = deepMerge(root, other);
	}
}

/// Deep-merge two JSON objects (`b` wins).
Json deepMerge(Json a, Json b)
{
	if (a.type != Json.Type.object || b.type != Json.Type.object)
		return b;
	auto r = a.clone;
	foreach (string k, v; b)
		r[k] = r[k].type == Json.Type.object && v.type == Json.Type.object ? deepMerge(r[k], v) : v;
	return r;
}

private __gshared Secrets g_secrets;
private __gshared Mutex g_lock;
shared static this() { g_lock = new Mutex; }

/// Files searched, lowest priority first.
string[] secretsSearchPaths()
{
	return [
		expandTilde("~/.streamlitd/secrets.toml"),
		buildPath(".streamlit", "secrets.toml"),
		buildPath(".streamlitd", "secrets.toml"),
	];
}

/// The process-wide secrets (loaded on first use).
Secrets secrets()
{
	synchronized (g_lock)
	{
		if (g_secrets is null)
		{
			auto s = new Secrets(Json.emptyObject);
			foreach (p; secretsSearchPaths())
				s.merge(readTomlFile(p));
			g_secrets = s;
		}
		return g_secrets;
	}
}

/// Replace the secrets (for tests or custom loading).
void setSecrets(Json root)
{
	synchronized (g_lock)
		g_secrets = new Secrets(root);
}

unittest
{
	auto s = new Secrets(parseToml("api_key = \"k1\"\n[db]\nuser = \"u\"\nport = 5432\n"));
	assert(s["api_key"].get!string == "k1");
	assert(s["db"]["user"].get!string == "u");
	assert(s.get!string("db.user") == "u");
	assert(s.get!int("db.port") == 5432);
	assert(s.get!string("db.missing", "x") == "x");
	assert("db" in s && !s.has("nope"));
	import std.exception : assertThrown;
	assertThrown!StreamlitAPIException(s["nope"]);
	s.merge(parseToml("[db]\nport = 1\n"));
	assert(s.get!int("db.port") == 1 && s.get!string("db.user") == "u");
}
