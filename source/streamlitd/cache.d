/// Caching: `cacheData!fn(args)` and `cacheResource!fn(args)`.
module streamlitd.cache;

import std.conv : to;
import std.datetime : Clock, SysTime;
import std.traits;
import std.variant;
import core.time : Duration, seconds;
import core.sync.mutex : Mutex;

private struct Entry
{
	Variant value;
	SysTime created;
}

private __gshared Entry[string][string] caches; // function id -> args key -> entry
private __gshared Mutex cacheLock;
shared static this() { cacheLock = new Mutex; }

private string argsKey(Args...)(Args args)
{
	import vibe.data.json : serializeToJsonString;
	string k;
	foreach (a; args)
	{
		static if (__traits(compiles, serializeToJsonString(a)))
			k ~= serializeToJsonString(a) ~ "\x1f";
		else
			k ~= a.to!string ~ "\x1f";
	}
	return k;
}

private ReturnType!fn cachedCall(alias fn, long ttlSeconds, size_t maxEntries)(Parameters!fn args)
{
	enum id = fullyQualifiedName!fn ~ "#" ~ ttlSeconds.to!string;
	auto k = argsKey(args);
	auto now = Clock.currTime;
	synchronized (cacheLock)
	{
		if (auto c = id in caches)
			if (auto e = k in *c)
			{
				if (ttlSeconds == 0 || now - e.created < ttlSeconds.seconds)
					return e.value.get!(ReturnType!fn);
				(*c).remove(k);
			}
	}
	auto v = fn(args); // computed outside the lock; concurrent misses may compute twice
	synchronized (cacheLock)
		storeEntry(id, k, Variant(v), now, maxEntries);
	return v;
}

private void storeEntry(string id, string k, Variant v, SysTime now, size_t maxEntries)
{
	if (id !in caches)
		caches[id] = null;
	if (maxEntries > 0 && caches[id].length >= maxEntries)
	{
		// evict the oldest entry
		string oldest;
		SysTime t = SysTime.max;
		foreach (kk, e; caches[id])
			if (e.created < t)
			{
				t = e.created;
				oldest = kk;
			}
		caches[id].remove(oldest);
	}
	caches[id][k] = Entry(v, now);
}

/// Memoize `fn` by its arguments (`@st.cache_data`). Shared between all sessions; like
/// Streamlit, callers get a copy (via `.dup`, e.g. arrays and `DataFrame`) so mutating the
/// result does not change the cache. `ttlSeconds` = 0 means no expiry; `maxEntries` = 0 means unbounded.
template cacheData(alias fn, long ttlSeconds = 0, size_t maxEntries = 0)
{
	ReturnType!fn cacheData(Parameters!fn args)
	{
		auto v = cachedCall!(fn, ttlSeconds, maxEntries)(args);
		static if (is(typeof(v.dup) : ReturnType!fn))
			return v is null ? v : v.dup;
		else
			return v;
	}
}

/// Shared resource cache (`@st.cache_resource`): the same object is returned to every session.
template cacheResource(alias fn)
{
	ReturnType!fn cacheResource(Parameters!fn args)
	{
		return cachedCall!(fn, 0, 0)(args);
	}
}

/// Clear the cache of one function.
void cacheClear(alias fn)()
{
	enum prefix = fullyQualifiedName!fn ~ "#";
	synchronized (cacheLock)
		removePrefix(prefix);
}

private void removePrefix(string prefix)
{
	string[] dead;
	foreach (k, _; caches)
		if (k.length >= prefix.length && k[0 .. prefix.length] == prefix)
			dead ~= k;
	foreach (k; dead)
		caches.remove(k);
}

/// Clear all caches (`st.cache_data.clear()`).
void clearAllCaches()
{
	synchronized (cacheLock)
		caches = null;
}

version (unittest)
{
	private int calls;
	private int square(int x) { calls++; return x * x; }
	private int[] arr(string s, int n) { calls++; return new int[n]; }
}

unittest
{
	calls = 0;
	assert(cacheData!square(3) == 9);
	assert(cacheData!square(3) == 9);
	assert(calls == 1);
	assert(cacheData!square(4) == 16);
	assert(calls == 2);
	cacheClear!square();
	assert(cacheData!square(3) == 9);
	assert(calls == 3);
	assert(cacheData!arr("a", 2).length == 2);
	assert(cacheData!arr("a", 2).length == 2);
	assert(calls == 4);
	clearAllCaches();
	// cacheData hands out copies, cacheResource the shared object
	auto a1 = cacheData!arr("b", 3);
	a1[0] = 42;
	assert(cacheData!arr("b", 3)[0] == 0);
	auto r1 = cacheResource!arr("c", 1);
	r1[0] = 7;
	assert(cacheResource!arr("c", 1)[0] == 7);
	clearAllCaches();
	cacheData!(square, 0, 1)(1);
	cacheData!(square, 0, 1)(2);
	assert(caches.values[0].length == 1);
}
