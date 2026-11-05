/// A small, column-oriented DataFrame used by `st.dataframe`, `st.table`,
/// `st.data_editor` and the chart elements.
module streamlitd.dataframe;

import std.algorithm;
import std.array;
import std.conv : to, ConvException;
import std.datetime : Date, DateTime, SysTime;
import std.exception : enforce;
import std.range;
import std.traits;
import vibe.data.json;

import streamlitd.util;
import std.algorithm.comparison : amin = min;

/// Logical column types (sent to the frontend for formatting/editing).
enum ColumnType { integer, number, text, boolean, date, datetime, object }

/// Name used in the protocol.
string typeName(ColumnType t)
{
	final switch (t)
	{
		case ColumnType.integer: return "integer";
		case ColumnType.number: return "number";
		case ColumnType.text: return "text";
		case ColumnType.boolean: return "boolean";
		case ColumnType.date: return "date";
		case ColumnType.datetime: return "datetime";
		case ColumnType.object: return "object";
	}
}

/// Map a D type to a column type.
template columnTypeOf(T)
{
	static if (is(T == bool))
		enum columnTypeOf = ColumnType.boolean;
	else static if (isIntegral!T)
		enum columnTypeOf = ColumnType.integer;
	else static if (isFloatingPoint!T)
		enum columnTypeOf = ColumnType.number;
	else static if (isSomeString!T)
		enum columnTypeOf = ColumnType.text;
	else static if (is(T == Date))
		enum columnTypeOf = ColumnType.date;
	else static if (is(T == DateTime) || is(T == SysTime))
		enum columnTypeOf = ColumnType.datetime;
	else
		enum columnTypeOf = ColumnType.object;
}

/// Convert a cell value to Json.
Json cellJ(T)(T v)
{
	static if (is(T == Date) || is(T == DateTime))
		return Json(v.toISOExtString());
	else static if (is(T == SysTime))
		return Json(v.toISOExtString());
	else
		return toJ(v);
}

/// Convert a Json cell to T.
T cellAs(T)(Json j)
{
	static if (is(T == Json))
		return j;
	else static if (is(T == bool))
	{
		if (j.type == Json.Type.bool_) return j.get!bool;
		if (j.type == Json.Type.string) return j.get!string == "true";
		if (j.type == Json.Type.int_) return j.get!long != 0;
		return false;
	}
	else static if (isNumeric!T)
	{
		switch (j.type)
		{
			case Json.Type.int_: return cast(T) j.get!long;
			case Json.Type.float_: return cast(T) j.get!double;
			case Json.Type.bool_: return cast(T) (j.get!bool ? 1 : 0);
			case Json.Type.string: return j.get!string.to!T;
			case Json.Type.null_:
				static if (isFloatingPoint!T) return T.nan; else return T.init;
			default: throw new Exception("cell is not numeric");
		}
	}
	else static if (isSomeString!T)
	{
		if (j.type == Json.Type.string) return j.get!string.to!T;
		if (j.type == Json.Type.null_ || j.type == Json.Type.undefined) return null;
		return j.toString.to!T;
	}
	else static if (is(T == Date))
		return Date.fromISOExtString(j.get!string[0 .. min($, 10)]);
	else static if (is(T == DateTime))
		return DateTime.fromISOExtString(j.get!string);
	else static if (is(T == SysTime))
		return SysTime.fromISOExtString(j.get!string);
	else
		return deserializeJson!T(j);
}

/// Order Json cells (nulls last).
int compareCells(Json a, Json b)
{
	bool an = a.type == Json.Type.null_ || a.type == Json.Type.undefined;
	bool bn = b.type == Json.Type.null_ || b.type == Json.Type.undefined;
	if (an || bn)
		return an == bn ? 0 : (an ? 1 : -1);
	bool anum = a.type == Json.Type.int_ || a.type == Json.Type.float_ || a.type == Json.Type.bool_;
	bool bnum = b.type == Json.Type.int_ || b.type == Json.Type.float_ || b.type == Json.Type.bool_;
	if (anum && bnum)
	{
		auto x = cellAs!double(a), y = cellAs!double(b);
		return x < y ? -1 : (x > y ? 1 : 0);
	}
	auto sa = cellAs!string(a), sb = cellAs!string(b);
	return sa < sb ? -1 : (sa > sb ? 1 : 0);
}

/// One row view.
struct Row
{
	DataFrame df;
	size_t index;

	/// Raw cell.
	Json opIndex(string col) { return df.cell(index, col); }
	/// Typed cell.
	T get(T)(string col) { return cellAs!T(df.cell(index, col)); }
}

/// Column-oriented table.
final class DataFrame
{
	private string[] names_;
	private ColumnType[] types_;
	private Json[][] cols_;

	this() {}

	// ------------------------------------------------------------ construction

	/// Build from a range of structs (or classes); each field becomes a column.
	static DataFrame fromStructs(R)(R rows) if (isInputRange!R)
	{
		alias T = ElementType!R;
		auto df = new DataFrame;
		static foreach (name; FieldNameTuple!T)
		{{
			alias F = typeof(__traits(getMember, T, name));
			df.names_ ~= name;
			df.types_ ~= columnTypeOf!F;
			df.cols_ ~= null;
		}}
		foreach (r; rows)
		{
			size_t ci = 0;
			static foreach (name; FieldNameTuple!T)
			{
				df.cols_[ci] ~= cellJ(__traits(getMember, r, name));
				ci++;
			}
		}
		return df;
	}

	/// Build from row arrays.
	static DataFrame fromRows(string[] names, Json[][] rows)
	{
		auto df = new DataFrame;
		df.names_ = names.dup;
		df.cols_ = new Json[][](names.length);
		foreach (r; rows)
		{
			enforce(r.length == names.length, "row length does not match column count");
			foreach (i, v; r)
				df.cols_[i] ~= v;
		}
		df.types_ = new ColumnType[names.length];
		foreach (i; 0 .. names.length)
			df.types_[i] = inferType(df.cols_[i]);
		return df;
	}

	/// Build from a JSON array of objects (records). JSON objects do not keep key order,
	/// so pass `columnOrder` to fix the column order; otherwise columns are sorted by name.
	static DataFrame fromJson(Json records, string[] columnOrder = null)
	{
		string[] names = columnOrder.dup;
		bool[string] seen;
		foreach (n; names)
			seen[n] = true;
		string[] extra;
		foreach (rec; records)
			foreach (string k, v; rec)
				if (k !in seen)
				{
					seen[k] = true;
					extra ~= k;
				}
		extra.sort();
		names ~= extra;
		Json[][] rows;
		foreach (rec; records)
		{
			Json[] r;
			foreach (n; names)
			{
				auto v = rec[n];
				r ~= v.type == Json.Type.undefined ? Json(null) : v;
			}
			rows ~= r;
		}
		return fromRows(names, rows);
	}

	/// Parse CSV text (first line = header). Column types are inferred.
	static DataFrame fromCsv(string text, dchar separator = ',')
	{
		import std.csv : csvReader, Malformed;
		auto recs = csvReader!(string, Malformed.ignore)(text, null, separator);
		string[] header = recs.header.dup;
		string[][] raw;
		foreach (rec; recs)
		{
			auto row = rec.array;
			if (row.length == 1 && row[0].length == 0 && header.length > 1)
				continue;
			raw ~= row;
		}
		auto df = new DataFrame;
		df.names_ = header;
		df.cols_ = new Json[][](header.length);
		df.types_ = new ColumnType[header.length];
		foreach (ci; 0 .. header.length)
		{
			auto t = inferCsvType(raw.map!(r => ci < r.length ? r[ci] : "").array);
			df.types_[ci] = t;
			foreach (r; raw)
				df.cols_[ci] ~= parseCsvCell(ci < r.length ? r[ci] : "", t);
		}
		return df;
	}

	/// Read a CSV file.
	static DataFrame readCsv(string path, dchar separator = ',')
	{
		import std.file : readText;
		return fromCsv(readText(path), separator);
	}

	/// Add (or replace) a column. Returns `this` for chaining.
	DataFrame addColumn(T)(string name, T[] values)
	{
		if (names_.length)
			enforce(values.length == length, "column '" ~ name ~ "' has " ~ values.length.to!string ~
				" values, expected " ~ length.to!string);
		Json[] c;
		c.reserve(values.length);
		foreach (v; values)
			c ~= cellJ(v);
		auto i = names_.countUntil(name);
		if (i >= 0)
		{
			cols_[i] = c;
			types_[i] = columnTypeOf!T;
		}
		else
		{
			names_ ~= name;
			types_ ~= columnTypeOf!T;
			cols_ ~= c;
		}
		return this;
	}

	/// Append a row given as Json cells.
	DataFrame appendRow(Json[] values)
	{
		enforce(values.length == names_.length, "row length does not match column count");
		foreach (i, v; values)
			cols_[i] ~= v;
		return this;
	}

	/// Append a row given as D values.
	DataFrame appendRow(Args...)(Args values) if (Args.length > 0 && !is(Args[0] == Json[]))
	{
		enforce(values.length == names_.length, "row length does not match column count");
		foreach (i, v; values)
			cols_[i] ~= cellJ(v);
		return this;
	}

	// ------------------------------------------------------------ accessors

	/// Number of rows.
	size_t length() const { return cols_.length ? cols_[0].length : 0; }
	/// Number of columns.
	size_t width() const { return names_.length; }
	/// Column names.
	const(string)[] columns() const { return names_; }
	/// Column types.
	const(ColumnType)[] types() const { return types_; }
	/// Type of a column.
	ColumnType typeOf(string col) const { return types_[colIndex(col)]; }
	/// True if the column exists.
	bool hasColumn(string col) const { return names_.canFind(col); }

	/// Index of a column (throws if missing).
	size_t colIndex(string col) const
	{
		auto i = names_.countUntil(col);
		enforce(i >= 0, "no column named '" ~ col ~ "'");
		return i;
	}

	/// Raw cell.
	Json cell(size_t row, string col) { return cols_[colIndex(col)][row]; }
	/// Raw cell by position.
	Json cell(size_t row, size_t col) { return cols_[col][row]; }
	/// Set a raw cell.
	void setCell(size_t row, string col, Json v) { cols_[colIndex(col)][row] = v; }

	/// Typed column values.
	T[] column(T)(string col)
	{
		return cols_[colIndex(col)].map!(j => cellAs!T(j)).array;
	}

	/// Raw column values.
	Json[] rawColumn(string col) { return cols_[colIndex(col)]; }

	/// Row view.
	Row row(size_t i) { return Row(this, i); }

	/// Iterate rows: `foreach (row; df)` or `foreach (i, row; df)`.
	int opApply(scope int delegate(Row) dg)
	{
		foreach (i; 0 .. length)
			if (auto r = dg(Row(this, i)))
				return r;
		return 0;
	}
	/// ditto
	int opApply(scope int delegate(size_t, Row) dg)
	{
		foreach (i; 0 .. length)
			if (auto r = dg(i, Row(this, i)))
				return r;
		return 0;
	}

	// ------------------------------------------------------------ transformations (return new frames)

	/// Deep copy.
	DataFrame dup()
	{
		auto df = new DataFrame;
		df.names_ = names_.dup;
		df.types_ = types_.dup;
		df.cols_ = cols_.map!(c => c.dup).array;
		return df;
	}

	private DataFrame takeRows(size_t[] idx)
	{
		auto df = new DataFrame;
		df.names_ = names_.dup;
		df.types_ = types_.dup;
		df.cols_ = new Json[][](names_.length);
		foreach (ci; 0 .. names_.length)
			foreach (r; idx)
				df.cols_[ci] ~= cols_[ci][r];
		return df;
	}

	/// First `n` rows.
	DataFrame head(size_t n = 5) { return takeRows(iota(amin(n, length)).array); }
	/// Last `n` rows.
	DataFrame tail(size_t n = 5) { return takeRows(iota(length - amin(n, length), length).array); }
	/// Rows `[from, to)`.
	DataFrame slice(size_t from, size_t to) { return takeRows(iota(amin(from, length), amin(to, length)).array); }

	/// Keep only the named columns, in the given order.
	DataFrame select(string[] cols...)
	{
		auto df = new DataFrame;
		foreach (c; cols)
		{
			auto i = colIndex(c);
			df.names_ ~= names_[i];
			df.types_ ~= types_[i];
			df.cols_ ~= cols_[i].dup;
		}
		return df;
	}

	/// Drop columns.
	DataFrame drop(string[] cols...)
	{
		return select(names_.filter!(n => !cols.canFind(n)).array);
	}

	/// Rows for which `pred` is true.
	DataFrame filter(scope bool delegate(Row) pred)
	{
		size_t[] idx;
		foreach (i; 0 .. length)
			if (pred(Row(this, i)))
				idx ~= i;
		return takeRows(idx);
	}

	/// Sort by a column.
	DataFrame sortBy(string col, bool ascending = true)
	{
		auto c = cols_[colIndex(col)];
		auto idx = iota(length).array;
		idx.sort!((a, b) {
			auto r = compareCells(c[a], c[b]);
			return ascending ? r < 0 : r > 0;
		}, SwapStrategy.stable);
		return takeRows(idx);
	}

	/// Rename a column.
	DataFrame rename(string from, string to)
	{
		auto df = dup;
		df.names_[colIndex(from)] = to;
		return df;
	}

	/// Group by `key` and aggregate `valueCols` with "sum", "mean", "count", "min" or "max".
	DataFrame groupBy(string key, string[] valueCols, string agg = "sum")
	{
		auto kc = cols_[colIndex(key)];
		string[] order;
		size_t[][string] groups;
		Json[string] keyVal;
		foreach (i, k; kc)
		{
			auto ks = cellAs!string(k);
			if (ks !in groups)
			{
				order ~= ks;
				keyVal[ks] = k;
			}
			groups[ks] ~= i;
		}
		auto df = new DataFrame;
		df.names_ = [key] ~ valueCols;
		df.types_ = [types_[colIndex(key)]];
		df.cols_ = new Json[][](1 + valueCols.length);
		foreach (k; order)
			df.cols_[0] ~= keyVal[k];
		foreach (vi, vc; valueCols)
		{
			auto c = cols_[colIndex(vc)];
			df.types_ ~= agg == "count" ? ColumnType.integer : ColumnType.number;
			foreach (k; order)
			{
				auto vals = groups[k].map!(i => cellAs!double(c[i])).array;
				double r;
				switch (agg)
				{
					case "sum": r = vals.sum; break;
					case "mean": r = vals.length ? vals.sum / vals.length : double.nan; break;
					case "count": r = vals.length; break;
					case "min": r = vals.length ? vals.minElement : double.nan; break;
					case "max": r = vals.length ? vals.maxElement : double.nan; break;
					default: throw new Exception("unknown aggregation '" ~ agg ~ "'");
				}
				df.cols_[1 + vi] ~= agg == "count" ? Json(cast(long) r) : toJ(r);
			}
		}
		return df;
	}

	// ------------------------------------------------------------ statistics

	/// Sum of a numeric column (nulls skipped).
	double sum(string col) { return numericValues(col).sum; }
	/// Mean of a numeric column.
	double mean(string col)
	{
		auto v = numericValues(col);
		return v.length ? v.sum / v.length : double.nan;
	}
	/// Minimum of a numeric column.
	double min(string col) { auto v = numericValues(col); return v.length ? v.minElement : double.nan; }
	/// Maximum of a numeric column.
	double max(string col) { auto v = numericValues(col); return v.length ? v.maxElement : double.nan; }

	private double[] numericValues(string col)
	{
		return cols_[colIndex(col)]
			.filter!(j => j.type == Json.Type.int_ || j.type == Json.Type.float_)
			.map!(j => cellAs!double(j)).array;
	}

	// ------------------------------------------------------------ export

	/// `{columns: [{name, type}], data: [[...row...]]}`
	Json toJson()
	{
		auto cols = Json.emptyArray;
		foreach (i, n; names_)
			cols ~= jo("name", n, "type", typeName(types_[i]));
		auto data = Json.emptyArray;
		foreach (r; 0 .. length)
		{
			auto row = Json.emptyArray;
			foreach (c; 0 .. names_.length)
				row ~= cols_[c][r];
			data.appendArrayElement(row);
		}
		return jo("columns", cols, "data", data);
	}

	/// Array of `{column: value}` objects.
	Json toRecords()
	{
		auto a = Json.emptyArray;
		foreach (r; 0 .. length)
		{
			auto o = Json.emptyObject;
			foreach (c, n; names_)
				o[n] = cols_[c][r];
			a ~= o;
		}
		return a;
	}

	/// CSV text.
	string toCsv(char separator = ',')
	{
		string esc(string s)
		{
			if (s.canFind(separator) || s.canFind('"') || s.canFind('\n'))
				return `"` ~ s.replace(`"`, `""`) ~ `"`;
			return s;
		}
		auto app = appender!string;
		app ~= names_.map!(n => esc(n)).join(separator);
		app ~= "\n";
		foreach (r; 0 .. length)
		{
			app ~= iota(names_.length).map!(c => esc(cellAs!string(cols_[c][r]))).join(separator);
			app ~= "\n";
		}
		return app.data;
	}

	override string toString()
	{
		return "DataFrame(" ~ length.to!string ~ " rows x " ~ width.to!string ~ " columns: " ~
			names_.join(", ") ~ ")";
	}

	package void setType(size_t i, ColumnType t) { types_[i] = t; }
}

private ColumnType inferType(Json[] values)
{
	ColumnType t = ColumnType.object;
	bool first = true;
	foreach (v; values)
	{
		ColumnType vt;
		switch (v.type)
		{
			case Json.Type.null_: case Json.Type.undefined: continue;
			case Json.Type.int_: case Json.Type.bigInt: vt = ColumnType.integer; break;
			case Json.Type.float_: vt = ColumnType.number; break;
			case Json.Type.bool_: vt = ColumnType.boolean; break;
			case Json.Type.string: vt = ColumnType.text; break;
			default: vt = ColumnType.object; break;
		}
		if (first)
		{
			t = vt;
			first = false;
		}
		else if (t != vt)
		{
			if ((t == ColumnType.integer && vt == ColumnType.number) || (t == ColumnType.number && vt == ColumnType.integer))
				t = ColumnType.number;
			else
				return ColumnType.object;
		}
	}
	return first ? ColumnType.text : t;
}

private ColumnType inferCsvType(string[] vals)
{
	import std.string : strip;
	bool allInt = true, allNum = true, allBool = true, allDate = true;
	size_t nonEmpty;
	foreach (s0; vals)
	{
		auto s = s0.strip;
		if (s.length == 0)
			continue;
		nonEmpty++;
		if (allInt) { try { s.to!long; } catch (ConvException) { allInt = false; } }
		if (allNum) { try { s.to!double; } catch (ConvException) { allNum = false; } }
		if (allBool) allBool = s == "true" || s == "false" || s == "True" || s == "False";
		if (allDate) { try { Date.fromISOExtString(s); } catch (Exception) { allDate = false; } }
	}
	if (nonEmpty == 0) return ColumnType.text;
	if (allInt) return ColumnType.integer;
	if (allNum) return ColumnType.number;
	if (allBool) return ColumnType.boolean;
	if (allDate) return ColumnType.date;
	return ColumnType.text;
}

private Json parseCsvCell(string s0, ColumnType t)
{
	import std.string : strip;
	auto s = s0.strip;
	if (s.length == 0 && t != ColumnType.text)
		return Json(null);
	switch (t)
	{
		case ColumnType.integer: return Json(s.to!long);
		case ColumnType.number: return toJ(s.to!double);
		case ColumnType.boolean: return Json(s == "true" || s == "True");
		default: return Json(s0);
	}
}

unittest
{
	struct Sale { string city; int units; double price; }
	auto df = DataFrame.fromStructs([Sale("A", 3, 1.5), Sale("B", 1, 2.0), Sale("A", 2, 3.0)]);
	assert(df.length == 3 && df.width == 3);
	assert(df.typeOf("units") == ColumnType.integer);
	assert(df.column!int("units") == [3, 1, 2]);
	assert(df.sortBy("units").column!int("units") == [1, 2, 3]);
	assert(df.sortBy("units", false).column!string("city") == ["A", "A", "B"]);
	assert(df.filter(r => r.get!string("city") == "A").length == 2);
	auto g = df.groupBy("city", ["units"], "sum");
	assert(g.column!string("city") == ["A", "B"]);
	assert(g.column!double("units") == [5, 1]);
	assert(df.sum("units") == 6);
	assert(df.head(2).length == 2 && df.tail(1).column!string("city") == ["A"]);
	assert(df.select("price", "city").columns == ["price", "city"]);

	auto c = DataFrame.fromCsv("name,age,score,ok,day\nann,31,1.5,true,2024-01-02\nbob,25,,false,2024-02-03\n");
	assert(c.length == 2);
	assert(c.typeOf("age") == ColumnType.integer);
	assert(c.typeOf("score") == ColumnType.number);
	assert(c.typeOf("ok") == ColumnType.boolean);
	assert(c.typeOf("day") == ColumnType.date);
	assert(c.cell(1, "score").type == Json.Type.null_);
	assert(c.toCsv().startsWith("name,age,score,ok,day\n"));

	auto o = DataFrame.fromJson(parseJsonString(`[{"z":1,"a":2,"m":3}]`), ["m"]);
	assert(o.columns == ["m", "a", "z"]);
	auto j = DataFrame.fromJson(parseJsonString(`[{"a":1,"b":"x"},{"a":2.5}]`));
	assert(j.typeOf("a") == ColumnType.number);
	assert(j.cell(1, "b").type == Json.Type.null_);

	auto b = new DataFrame;
	b.addColumn("x", [1, 2, 3]).addColumn("y", ["a", "b", "c"]);
	assert(b.length == 3);
	b.appendRow(4, "d");
	assert(b.length == 4);
	assert(b.toJson()["data"][3][1].get!string == "d");
}
