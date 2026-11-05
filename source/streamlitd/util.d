/// Internal helpers: JSON construction, ids, hashing.
module streamlitd.util;

import vibe.data.json;
import std.traits;
import std.conv : to;

/// Build a JSON object from alternating key/value arguments.
/// Values are converted with `toJ`. `null`-valued strings are skipped.
Json jo(Args...)(Args args)
{
	static assert(Args.length % 2 == 0, "jo() needs key/value pairs");
	auto o = Json.emptyObject;
	static foreach (i; 0 .. Args.length / 2)
	{{
		static assert(is(Args[2 * i] : string), "jo() keys must be strings");
		o[args[2 * i]] = toJ(args[2 * i + 1]);
	}}
	return o;
}

/// Convert an arbitrary D value to Json.
Json toJ(T)(T v)
{
	static if (is(T == Json))
		return v;
	else static if (is(T == typeof(null)))
		return Json(null);
	else static if (isSomeString!T)
		return v is null ? Json(null) : Json(v.to!string);
	else static if (is(T == bool))
		return Json(v);
	else static if (isIntegral!T)
		return Json(cast(long) v);
	else static if (isFloatingPoint!T)
	{
		import std.math : isNaN, isInfinity;
		if (isNaN(v) || isInfinity(v))
			return Json(null);
		return Json(cast(double) v);
	}
	else static if (isArray!T)
	{
		auto a = Json.emptyArray;
		foreach (e; v)
			a.appendArrayElement(toJ(e));
		return a;
	}
	else static if (isAssociativeArray!T)
	{
		auto o = Json.emptyObject;
		foreach (k, e; v)
			o[k.to!string] = toJ(e);
		return o;
	}
	else static if (__traits(compiles, v.toJson()))
		return v.toJson();
	else
		return serializeToJson(v);
}

/// Stable short hash as hex string (FNV-1a 64).
string hashHex(const(char)[] s)
{
	import std.format : format;
	ulong h = 0xcbf29ce484222325UL;
	foreach (c; cast(const(ubyte)[]) s)
	{
		h ^= c;
		h *= 0x100000001b3UL;
	}
	return format("%016x", h);
}

/// Hash for binary data (used for media ids).
string hashBytes(const(ubyte)[] data, string salt = null)
{
	import std.digest.sha : sha1Of, toHexString;
	import std.digest : LetterCase;
	auto d = sha1Of(cast(const(ubyte)[]) salt ~ data);
	return toHexString!(LetterCase.lower)(d).idup[0 .. 24];
}

/// Random identifier.
string randomId()
{
	import std.uuid : randomUUID;
	return randomUUID().toString();
}

/// Key for a delta path, e.g. "0.3.1".
string pathKey(const int[] path)
{
	import std.algorithm : map;
	import std.array : join;
	return path.map!(p => p.to!string).join(".");
}

/// Format a value for display in option lists.
string displayString(T)(T v)
{
	static if (isSomeString!T)
		return v.to!string;
	else
		return v.to!string;
}

/// Guess a MIME type from a file name.
string mimeFromName(string name)
{
	import std.path : extension;
	import std.uni : toLower;
	switch (name.extension.toLower)
	{
		case ".png": return "image/png";
		case ".jpg": case ".jpeg": return "image/jpeg";
		case ".gif": return "image/gif";
		case ".svg": return "image/svg+xml";
		case ".webp": return "image/webp";
		case ".bmp": return "image/bmp";
		case ".ico": return "image/x-icon";
		case ".csv": return "text/csv";
		case ".txt": return "text/plain";
		case ".json": return "application/json";
		case ".html": case ".htm": return "text/html";
		case ".pdf": return "application/pdf";
		case ".zip": return "application/zip";
		case ".xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
		case ".mp3": return "audio/mpeg";
		case ".wav": return "audio/wav";
		case ".mp4": return "video/mp4";
		case ".webm": return "video/webm";
		default: return "application/octet-stream";
	}
}

/// Guess an image MIME type from magic bytes.
string mimeFromBytes(const(ubyte)[] d)
{
	if (d.length >= 8 && d[0 .. 8] == [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A]) return "image/png";
	if (d.length >= 3 && d[0 .. 3] == [0xFF, 0xD8, 0xFF]) return "image/jpeg";
	if (d.length >= 4 && d[0 .. 4] == cast(const(ubyte)[]) "GIF8") return "image/gif";
	if (d.length >= 12 && d[0 .. 4] == cast(const(ubyte)[]) "RIFF" && d[8 .. 12] == cast(const(ubyte)[]) "WEBP") return "image/webp";
	if (d.length >= 5 && (d[0 .. 4] == cast(const(ubyte)[]) "<svg" || d[0 .. 5] == cast(const(ubyte)[]) "<?xml")) return "image/svg+xml";
	return "application/octet-stream";
}

unittest
{
	auto j = jo("a", 1, "b", "x", "c", [1, 2], "d", 1.5, "e", true);
	assert(j["a"].get!long == 1);
	assert(j["b"].get!string == "x");
	assert(j["c"].length == 2);
	assert(j["e"].get!bool);
	assert(hashHex("abc") == hashHex("abc"));
	assert(hashHex("abc") != hashHex("abd"));
	assert(pathKey([0, 1, 2]) == "0.1.2");
	assert(mimeFromName("a.PNG") == "image/png");
}
