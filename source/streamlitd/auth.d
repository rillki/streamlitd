/// Authentication helpers: PBKDF2 password hashes and signed session cookies.
/// The login routes and `st.user` are built on these (see `streamlitd.server`).
module streamlitd.auth;

import std.base64 : Base64, Base64URLNoPadding;
import std.conv : to;
import std.digest.hmac : HMAC, hmac;
import std.digest.sha : SHA256, sha256Of;
import std.array : split;
import std.datetime : Clock;

/// PBKDF2-HMAC-SHA256 (RFC 8018).
ubyte[] pbkdf2Sha256(const(ubyte)[] password, const(ubyte)[] salt, uint iterations, size_t dkLen)
{
	ubyte[] result;
	uint block = 1;
	while (result.length < dkLen)
	{
		ubyte[4] be = [cast(ubyte)(block >> 24), cast(ubyte)(block >> 16), cast(ubyte)(block >> 8), cast(ubyte) block];
		auto u = (salt ~ be[]).hmac!SHA256(password);
		ubyte[32] t = u;
		foreach (_; 1 .. iterations)
		{
			u = u[].hmac!SHA256(password);
			t[] ^= u[];
		}
		result ~= t[];
		block++;
	}
	return result[0 .. dkLen];
}

/// Default iteration count for new hashes.
enum defaultIterations = 200_000;

/// Hash a password: `pbkdf2_sha256$<iterations>$<salt>$<hash>` (base64), Django-style.
string hashPasswordString(string password, uint iterations = defaultIterations)
{
	auto salt = randomBytes(16);
	auto dk = pbkdf2Sha256(cast(const(ubyte)[]) password, salt, iterations, 32);
	return "pbkdf2_sha256$" ~ iterations.to!string ~ "$" ~ Base64.encode(salt).idup ~ "$" ~ Base64.encode(dk).idup;
}

/// Verify a password against a hash produced by `hashPasswordString`.
bool verifyPassword(string password, string encoded)
{
	auto parts = encoded.split("$");
	if (parts.length != 4 || parts[0] != "pbkdf2_sha256")
		return false;
	try
	{
		auto iters = parts[1].to!uint;
		auto salt = Base64.decode(parts[2]);
		auto expected = Base64.decode(parts[3]);
		auto dk = pbkdf2Sha256(cast(const(ubyte)[]) password, salt, iters, expected.length);
		return constantTimeEquals(dk, expected);
	}
	catch (Exception)
		return false;
}

/// Compare without early exit.
bool constantTimeEquals(const(ubyte)[] a, const(ubyte)[] b)
{
	if (a.length != b.length)
		return false;
	ubyte d = 0;
	foreach (i; 0 .. a.length)
		d |= a[i] ^ b[i];
	return d == 0;
}

/// Cryptographically random bytes (from /dev/urandom, falling back to std.random).
ubyte[] randomBytes(size_t n)
{
	auto r = new ubyte[n];
	try
	{
		import std.stdio : File;
		auto f = File("/dev/urandom", "rb");
		f.rawRead(r);
		return r;
	}
	catch (Exception)
	{
		import std.random : uniform, unpredictableSeed, Mt19937;
		auto g = Mt19937(unpredictableSeed);
		foreach (ref b; r)
			b = cast(ubyte) uniform(0, 256, g);
		return r;
	}
}

/// Sign `payload` (any string) with HMAC-SHA256: `<payload-b64>.<sig-b64>`.
string signValue(string payload, const(ubyte)[] secret)
{
	auto p = Base64URLNoPadding.encode(cast(const(ubyte)[]) payload).idup;
	auto sig = (cast(const(ubyte)[]) p).hmac!SHA256(secret);
	return p ~ "." ~ Base64URLNoPadding.encode(sig[]).idup;
}

/// Verify a signed value; returns the payload or `null`.
string verifySigned(string signed, const(ubyte)[] secret)
{
	auto parts = signed.split(".");
	if (parts.length != 2)
		return null;
	try
	{
		auto sig = (cast(const(ubyte)[]) parts[0]).hmac!SHA256(secret);
		if (!constantTimeEquals(sig[], Base64URLNoPadding.decode(parts[1])))
			return null;
		return cast(string) Base64URLNoPadding.decode(parts[0]).idup;
	}
	catch (Exception)
		return null;
}

unittest
{
	// RFC 7914 section 11 / common PBKDF2-HMAC-SHA256 test vectors
	import std.digest : toHexString, LetterCase;
	auto dk = pbkdf2Sha256(cast(const(ubyte)[]) "passwd", cast(const(ubyte)[]) "salt", 1, 64);
	assert(toHexString!(LetterCase.lower)(dk) ==
		"55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783");
	auto dk2 = pbkdf2Sha256(cast(const(ubyte)[]) "password", cast(const(ubyte)[]) "salt", 2, 32);
	assert(toHexString!(LetterCase.lower)(dk2) == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43");

	auto h = hashPasswordString("s3cret", 1000);
	assert(verifyPassword("s3cret", h));
	assert(!verifyPassword("wrong", h));
	assert(!verifyPassword("s3cret", "garbage"));

	auto key = cast(const(ubyte)[]) "k";
	auto sv = signValue(`{"u":"ann"}`, key);
	assert(verifySigned(sv, key) == `{"u":"ann"}`);
	assert(verifySigned(sv, cast(const(ubyte)[]) "other") is null);
	assert(verifySigned(sv ~ "x", key) is null);
}
