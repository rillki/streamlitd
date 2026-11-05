/// Minimal TOML parser (the subset used by config.toml / secrets.toml) producing `Json`.
///
/// Supports: comments, `[table]`, `[a.b]`, `[[array.of.tables]]`, bare/quoted/dotted keys,
/// basic and literal strings (also multi-line), integers (`_`, hex/oct/bin), floats, booleans,
/// arrays (multi-line, trailing comma) and inline tables. Dates/times are kept as strings.
module streamlitd.toml;

import std.conv : to;
import std.exception : enforce;
import std.string : format;
import vibe.data.json;

/// Thrown on malformed input.
class TomlException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__) { super(msg, file, line); }
}

/// Parse TOML text into a JSON object.
Json parseToml(string src)
{
	auto p = Parser(src);
	return p.parseDocument();
}

/// Parse a TOML file; returns an empty object if the file does not exist.
Json readTomlFile(string path)
{
	import std.file : exists, readText;
	if (!exists(path))
		return Json.emptyObject;
	try
		return parseToml(readText(path));
	catch (TomlException e)
		throw new TomlException(path ~ ": " ~ e.msg);
}

private struct Parser
{
	string s;
	size_t i;
	size_t line = 1;

	this(string src) { s = src; }

	noreturn fail(string msg) { throw new TomlException(format("line %d: %s", line, msg)); }

	bool eof() const { return i >= s.length; }
	char peek(size_t o = 0) const { return i + o < s.length ? s[i + o] : '\0'; }

	void skipWs()
	{
		while (!eof && (peek == ' ' || peek == '\t'))
			i++;
	}

	void skipComment()
	{
		if (peek == '#')
			while (!eof && peek != '\n')
				i++;
	}

	/// Skip whitespace, newlines and comments.
	void skipAll()
	{
		while (!eof)
		{
			auto c = peek;
			if (c == ' ' || c == '\t' || c == '\r')
				i++;
			else if (c == '\n')
			{
				i++;
				line++;
			}
			else if (c == '#')
				skipComment();
			else
				break;
		}
	}

	void expectLineEnd()
	{
		skipWs();
		skipComment();
		if (peek == '\r')
			i++;
		if (!eof && peek != '\n')
			fail("expected end of line, found '" ~ peek ~ "'");
	}

	Json parseDocument()
	{
		auto root = Json.emptyObject;
		Json* current = &root;
		while (true)
		{
			skipAll();
			if (eof)
				break;
			if (peek == '[')
			{
				bool arr = peek(1) == '[';
				i += arr ? 2 : 1;
				skipWs();
				auto keys = parseKeyPath();
				skipWs();
				if (peek != ']' || (arr && peek(1) != ']'))
					fail("expected ']'");
				i += arr ? 2 : 1;
				expectLineEnd();
				current = arr ? appendTableArray(&root, keys) : descend(&root, keys);
			}
			else
			{
				auto keys = parseKeyPath();
				skipWs();
				if (peek != '=')
					fail("expected '=' after key");
				i++;
				skipWs();
				auto v = parseValue();
				auto t = descend(current, keys[0 .. $ - 1]);
				if ((*t)[keys[$ - 1]].type != Json.Type.undefined)
					fail("duplicate key '" ~ keys[$ - 1] ~ "'");
				(*t)[keys[$ - 1]] = v;
				expectLineEnd();
			}
		}
		return root;
	}

	Json* descend(Json* t, string[] keys)
	{
		foreach (k; keys)
		{
			auto next = (*t)[k];
			if (next.type == Json.Type.undefined)
				(*t)[k] = Json.emptyObject;
			else if (next.type == Json.Type.array && next.length)
			{
				t = &(*t)[k][next.length - 1];
				continue;
			}
			else if (next.type != Json.Type.object)
				fail("key '" ~ k ~ "' is not a table");
			t = &(*t)[k];
		}
		return t;
	}

	Json* appendTableArray(Json* root, string[] keys)
	{
		auto parent = descend(root, keys[0 .. $ - 1]);
		auto k = keys[$ - 1];
		if ((*parent)[k].type == Json.Type.undefined)
			(*parent)[k] = Json.emptyArray;
		if ((*parent)[k].type != Json.Type.array)
			fail("key '" ~ k ~ "' is not an array of tables");
		(*parent)[k].appendArrayElement(Json.emptyObject);
		return &(*parent)[k][(*parent)[k].length - 1];
	}

	string[] parseKeyPath()
	{
		string[] keys;
		while (true)
		{
			skipWs();
			keys ~= parseKey();
			skipWs();
			if (peek == '.')
			{
				i++;
				continue;
			}
			break;
		}
		return keys;
	}

	string parseKey()
	{
		if (peek == '"')
			return parseBasicString();
		if (peek == '\'')
			return parseLiteralString();
		auto st = i;
		while (!eof)
		{
			auto c = peek;
			if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-')
				i++;
			else
				break;
		}
		if (st == i)
			fail("expected a key");
		return s[st .. i];
	}

	Json parseValue()
	{
		auto c = peek;
		if (c == '"')
		{
			if (peek(1) == '"' && peek(2) == '"')
				return Json(parseMultiBasic());
			return Json(parseBasicString());
		}
		if (c == '\'')
		{
			if (peek(1) == '\'' && peek(2) == '\'')
				return Json(parseMultiLiteral());
			return Json(parseLiteralString());
		}
		if (c == '[')
			return parseArray();
		if (c == '{')
			return parseInlineTable();
		if (s[i .. $].length >= 4 && s[i .. i + 4] == "true")
		{
			i += 4;
			return Json(true);
		}
		if (s[i .. $].length >= 5 && s[i .. i + 5] == "false")
		{
			i += 5;
			return Json(false);
		}
		return parseNumberOrDate();
	}

	Json parseNumberOrDate()
	{
		auto st = i;
		while (!eof)
		{
			auto c = peek;
			if (c == ',' || c == ']' || c == '}' || c == '\n' || c == '\r' || c == '#' || c == '\t')
				break;
			if (c == ' ' && !(i > st && isDateLike(s[st .. i]) && peek(1) >= '0' && peek(1) <= '9'))
				break;
			i++;
		}
		auto tok = s[st .. i];
		if (tok.length == 0)
			fail("expected a value");
		if (isDateLike(tok))
			return Json(tok);
		import std.array : replace;
		auto t = tok.replace("_", "");
		try
		{
			if (t == "inf" || t == "+inf") return Json(double.infinity);
			if (t == "-inf") return Json(-double.infinity);
			if (t == "nan" || t == "+nan" || t == "-nan") return Json(double.nan);
			if (t.length > 2 && t[0] == '0' && (t[1] == 'x' || t[1] == 'o' || t[1] == 'b'))
				return Json(t[2 .. $].to!long(t[1] == 'x' ? 16 : t[1] == 'o' ? 8 : 2));
			import std.algorithm : canFind;
			if (t.canFind('.') || t.canFind('e') || t.canFind('E'))
				return Json(t.to!double);
			return Json(t.to!long);
		}
		catch (Exception)
			fail("invalid value '" ~ tok ~ "'");
	}

	static bool isDateLike(string t)
	{
		return t.length >= 8 && ((t[2] == ':' ) || (t.length >= 10 && t[4] == '-' && t[7] == '-'));
	}

	string parseBasicString()
	{
		i++; // opening quote
		string r;
		while (true)
		{
			if (eof || peek == '\n')
				fail("unterminated string");
			auto c = peek;
			if (c == '"')
			{
				i++;
				return r;
			}
			if (c == '\\')
				r ~= parseEscape();
			else
			{
				r ~= c;
				i++;
			}
		}
	}

	string parseEscape()
	{
		i++; // backslash
		auto c = peek;
		i++;
		switch (c)
		{
			case 'n': return "\n";
			case 't': return "\t";
			case 'r': return "\r";
			case 'b': return "\b";
			case 'f': return "\f";
			case '"': return "\"";
			case '\\': return "\\";
			case 'u':
			case 'U':
				auto n = c == 'u' ? 4 : 8;
				if (i + n > s.length)
					fail("bad unicode escape");
				auto cp = s[i .. i + n].to!uint(16);
				i += n;
				return (cast(dchar) cp).to!string;
			default:
				fail("invalid escape '\\" ~ c ~ "'");
		}
	}

	string parseLiteralString()
	{
		i++;
		auto st = i;
		while (!eof && peek != '\'')
		{
			if (peek == '\n')
				fail("unterminated string");
			i++;
		}
		if (eof)
			fail("unterminated string");
		auto r = s[st .. i];
		i++;
		return r;
	}

	string parseMultiBasic()
	{
		i += 3;
		if (peek == '\r') i++;
		if (peek == '\n') { i++; line++; }
		string r;
		while (true)
		{
			if (eof)
				fail("unterminated multi-line string");
			if (peek == '"' && peek(1) == '"' && peek(2) == '"')
			{
				i += 3;
				return r;
			}
			if (peek == '\\')
			{
				// line-ending backslash trims following whitespace
				size_t j = i + 1;
				while (j < s.length && (s[j] == ' ' || s[j] == '\t' || s[j] == '\r'))
					j++;
				if (j < s.length && s[j] == '\n')
				{
					i = j;
					while (!eof && (peek == ' ' || peek == '\t' || peek == '\n' || peek == '\r'))
					{
						if (peek == '\n') line++;
						i++;
					}
					continue;
				}
				r ~= parseEscape();
				continue;
			}
			if (peek == '\n')
				line++;
			r ~= peek;
			i++;
		}
	}

	string parseMultiLiteral()
	{
		i += 3;
		if (peek == '\r') i++;
		if (peek == '\n') { i++; line++; }
		auto st = i;
		while (true)
		{
			if (eof)
				fail("unterminated multi-line string");
			if (peek == '\'' && peek(1) == '\'' && peek(2) == '\'')
			{
				auto r = s[st .. i];
				i += 3;
				return r;
			}
			if (peek == '\n')
				line++;
			i++;
		}
	}

	Json parseArray()
	{
		i++;
		auto a = Json.emptyArray;
		while (true)
		{
			skipAll();
			if (peek == ']')
			{
				i++;
				return a;
			}
			a.appendArrayElement(parseValue());
			skipAll();
			if (peek == ',')
			{
				i++;
				continue;
			}
			if (peek == ']')
			{
				i++;
				return a;
			}
			fail("expected ',' or ']' in array");
		}
	}

	Json parseInlineTable()
	{
		i++;
		auto o = Json.emptyObject;
		skipWs();
		if (peek == '}')
		{
			i++;
			return o;
		}
		while (true)
		{
			skipWs();
			auto keys = parseKeyPath();
			skipWs();
			if (peek != '=')
				fail("expected '=' in inline table");
			i++;
			skipWs();
			auto v = parseValue();
			auto t = descend(&o, keys[0 .. $ - 1]);
			(*t)[keys[$ - 1]] = v;
			skipWs();
			if (peek == ',')
			{
				i++;
				continue;
			}
			if (peek == '}')
			{
				i++;
				return o;
			}
			fail("expected ',' or '}' in inline table");
		}
	}
}

unittest
{
	auto j = parseToml(`
# comment
title = "streamlitd" # trailing
count = 1_000
hex = 0xff
pi = 3.14
on = true
when = 2024-01-02
lit = 'C:\path'
esc = "a\tb\u00e9"
multi = """
line1
line2"""
arr = [1, 2,
  3, ]   # trailing comma
nested = { a = 1, b.c = "x" }
"quoted key" = 1

[server]
port = 8501
address = "0.0.0.0"

[theme]
preset = "ocean"

[a.b]
c = [ "x", 'y' ]

[[users]]
name = "ann"
[[users]]
name = "bob"
`);
	assert(j["title"].get!string == "streamlitd");
	assert(j["count"].get!long == 1000);
	assert(j["hex"].get!long == 255);
	assert(j["pi"].get!double == 3.14);
	assert(j["on"].get!bool);
	assert(j["when"].get!string == "2024-01-02");
	assert(j["lit"].get!string == `C:\path`);
	assert(j["esc"].get!string == "a\tbé");
	assert(j["multi"].get!string == "line1\nline2");
	assert(j["arr"].length == 3);
	assert(j["nested"]["b"]["c"].get!string == "x");
	assert(j["quoted key"].get!long == 1);
	assert(j["server"]["port"].get!long == 8501);
	assert(j["a"]["b"]["c"][1].get!string == "y");
	assert(j["users"].length == 2 && j["users"][1]["name"].get!string == "bob");

	import std.exception : assertThrown;
	assertThrown!TomlException(parseToml("a = "));
	assertThrown!TomlException(parseToml("a = 1\na = 2"));
	assertThrown!TomlException(parseToml(`a = "unterminated`));
	assertThrown!TomlException(parseToml("[a\nb = 1"));
}
