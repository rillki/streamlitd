/// `st.session` — per-browser-session state that survives reruns.
module streamlitd.state;

import std.variant;
import std.traits;
import streamlitd.errors;

/// Session state, the D counterpart of `st.session_state`.
/// Stores arbitrary D values (class instances included) as `Variant`.
final class SessionState
{
	private Variant[string] values;
	package bool[string] dirty; // keys assigned by user code since the bound widget last rendered

	/// Read a value. Throws `StreamlitAPIException` if missing.
	Variant opIndex(string key)
	{
		if (auto p = key in values)
			return *p;
		throw new StreamlitAPIException(`st.session has no key "` ~ key ~ `". Did you forget to initialize it?`);
	}

	/// Assign a value.
	void opIndexAssign(T)(T value, string key)
	{
		static if (is(T == Variant))
			values[key] = value;
		else
			values[key] = Variant(value);
		dirty[key] = true;
	}

	/// Typed read with default.
	T get(T)(string key, T def = T.init)
	{
		if (auto p = key in values)
			return convertVariant!T(*p, key);
		return def;
	}

	/// Set if missing, then return the (typed) value.
	T setDefault(T)(string key, T def)
	{
		if (key !in values)
			values[key] = Variant(def);
		return get!T(key, def);
	}

	/// True if the key exists.
	bool has(string key) const { return (key in values) !is null; }

	/// `"key" in st.session`
	bool opBinaryRight(string op : "in")(string key) const { return has(key); }

	/// Remove a key.
	void remove(string key) { values.remove(key); dirty.remove(key); }

	/// All keys.
	string[] keys() const { return values.keys; }

	/// Remove all keys.
	void clear() { values = null; dirty = null; }

	/// Number of keys.
	size_t length() const { return values.length; }

	package void setRaw(string key, Variant v)
	{
		values[key] = v;
		dirty.remove(key);
	}

	package Variant* rawPtr(string key) { return key in values; }
}

/// Convert a Variant to T, coercing numeric types.
T convertVariant(T)(Variant v, string key = null)
{
	if (v.convertsTo!T)
		return v.get!T;
	static if (isNumeric!T)
	{
		if (v.convertsTo!real)
			return cast(T) v.get!real;
		if (v.convertsTo!long)
			return cast(T) v.get!long;
	}
	static if (is(T == string))
		return v.toString();
	else
		throw new StreamlitAPIException("st.session[\"" ~ key ~ "\"] holds a " ~ v.type.toString ~
			", not a " ~ T.stringof);
}

unittest
{
	auto s = new SessionState;
	s["count"] = 1;
	assert(s.get!int("count") == 1);
	assert(s.get!double("count") == 1.0);
	assert("count" in s);
	assert(s.setDefault("x", "hi") == "hi");
	s.remove("x");
	assert(!s.has("x"));
	assert(s.get!int("missing", 7) == 7);
	class Obj { int v = 3; }
	s["obj"] = new Obj;
	assert(s.get!Obj("obj").v == 3);
}
