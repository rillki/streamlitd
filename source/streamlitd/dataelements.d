/// DataFrame display and editing elements.
module streamlitd.dataelements;

import std.conv : to;
import vibe.data.json;

import streamlitd.dataframe;
import streamlitd.util;
import streamlitd.columnconfig;

/// May `v` (already converted to the column type) go into a column configured as `c`? Used to
/// reject edits the browser should not have sent (read-only columns, values outside min/max or
/// the options, empty required cells, too long text).
package bool cellAllowed(Json v, const ColumnConfig c)
{
	import std.algorithm : canFind;
	import std.math : isNaN;
	immutable empty = v.type == Json.Type.null_ || v.type == Json.Type.undefined
		|| (v.type == Json.Type.string && v.get!string.length == 0);
	if (empty)
		return !c.required;
	if (c.type == "select" && c.options.length)
		return v.type == Json.Type.string && c.options.canFind(v.get!string);
	if (v.type == Json.Type.int_ || v.type == Json.Type.float_)
	{
		auto d = v.type == Json.Type.int_ ? cast(double) v.get!long : v.get!double;
		if ((!isNaN(c.min) && d < c.min) || (!isNaN(c.max) && d > c.max))
			return false;
	}
	if (c.maxChars && v.type == Json.Type.string && v.get!string.length > c.maxChars)
		return false;
	return true;
}

/// Apply a data_editor state (`{edited, added, deleted}`) to a frame.
/// Returns the resulting frame and fills `rowMap` with the source of each output row
/// (original row index, or `-(k+1)` for the k-th added row).
DataFrame applyEditorState(DataFrame src, Json state, out long[] rowMap, const ColumnConfig[string] config = null,
	const string[] disabledCols = null, size_t maxRows = 0)
{
	import std.algorithm : canFind;
	auto df = src.dup;
	bool[long] deleted;
	if (state.type == Json.Type.object)
	{
		if (state["deleted"].type == Json.Type.array)
			foreach (d; state["deleted"])
				deleted[d.to!long] = true;
		if (state["edited"].type == Json.Type.object)
			foreach (string r, cells; state["edited"])
			{
				auto ri = r.to!size_t;
				if (ri >= df.length)
					continue;
				foreach (string c, v; cells)
				{
					if (!df.hasColumn(c) || disabledCols.canFind(c))
						continue;
					auto cv = coerceCell(v, df.typeOf(c));
					if (auto cc = c in config)
						if (cc.disabled || !cellAllowed(cv, *cc))
							continue; // keep the old value
					df.setCell(ri, c, cv);
				}
			}
	}
	auto res = new DataFrame;
	foreach (ci, n; df.columns)
		res.addColumn!Json(n, []);
	foreach (ci; 0 .. df.width)
		res.setType(ci, df.types[ci]);
	foreach (i; 0 .. df.length)
	{
		if (cast(long) i in deleted)
			continue;
		Json[] row;
		foreach (c; 0 .. df.width)
			row ~= df.cell(i, c);
		res.appendRow(row);
		rowMap ~= cast(long) i;
	}
	if (state.type == Json.Type.object && state["added"].type == Json.Type.array)
	{
		long k = 0;
		foreach (a; state["added"])
		{
			if (maxRows && rowMap.length >= maxRows)
				break; // more rows than allowed: the rest is ignored
			Json[] row;
			foreach (ci, n; df.columns)
			{
				auto v = a.type == Json.Type.object && n in a ? a[n] : Json.undefined;
				auto cv = v.type == Json.Type.undefined ? Json(null) : coerceCell(v, df.types[ci]);
				if (auto cc = n in config)
					if (cv.type != Json.Type.null_ && !cellAllowed(cv, *cc))
						cv = Json(null); // a new row may still be incomplete; invalid values are dropped
				row ~= cv;
			}
			res.appendRow(row);
			rowMap ~= -(k + 1);
			k++;
		}
	}
	return res;
}

/// Convert an edited value coming from the browser to the column type.
Json coerceCell(Json v, ColumnType t)
{
	try
	{
		if (v.type == Json.Type.null_ || v.type == Json.Type.undefined)
			return Json(null);
		final switch (t)
		{
			case ColumnType.integer:
				if (v.type == Json.Type.string && v.get!string.length == 0) return Json(null);
				return Json(cellAs!long(v));
			case ColumnType.number:
				if (v.type == Json.Type.string && v.get!string.length == 0) return Json(null);
				return toJ(cellAs!double(v));
			case ColumnType.boolean: return Json(cellAs!bool(v));
			case ColumnType.text: case ColumnType.date: case ColumnType.datetime:
				return Json(cellAs!string(v));
			case ColumnType.object: return v;
		}
	}
	catch (Exception)
		return Json(null);
}

/// A cell picked in a `single-cell` selection.
struct TableCell
{
	size_t row;     /// row of the frame passed to `st.dataframe`
	string column;  /// column name
}

/// What the viewer selected in an `st.dataframe(..., onSelect: "rerun")`.
struct TableSelection
{
	size_t[] rows;      /// selected rows: indices into the frame passed in (stable under sorting and search)
	Json[] keys;        /// the `rowKey` values of the selected rows
	TableCell[] cells;  /// the selected cell (`selectionMode: "single-cell"`)
	string[] group;     /// a selected group row of a tree table (`groupBy`): its path, e.g. ["Ann", "ACME"]

	/// Nothing selected?
	bool empty() const { return rows.length == 0 && cells.length == 0 && group.length == 0; }
}

/// Decode and check a selection sent by the browser against the frame. Unknown rows, columns and
/// groups are dropped; with `rowKey`, rows are found by their key (so a selection survives
/// filtering and reordering of the frame).
package TableSelection decodeSelection(Json j, DataFrame d, string mode, string rowKey, const string[] groupBy)
{
	import std.algorithm : canFind;
	TableSelection s;
	if (j.type != Json.Type.object)
		return s;
	// without a rowKey, row numbers only mean something for the same rows: drop a selection made
	// on a frame of another length (also for keyed tables, whose widget id does not change)
	if (!rowKey.length && j["n"].type == Json.Type.int_ && j["n"].get!long != cast(long) d.length)
		return s;
	immutable multi = mode == "multi-row";
	// linear in the payload and the frame, and never more entries than rows: a crafted message
	// with huge lists must not keep the worker thread busy
	auto taken = new bool[d.length];
	immutable limit = 2 * d.length + 1;
	if (rowKey.length && j["keys"].type == Json.Type.array)
	{
		auto kc = d.colIndex(rowKey);
		size_t[][string] byKey; // a key's rows (keys may repeat), in frame order
		foreach (r; 0 .. d.length)
			byKey[d.cell(r, kc).toString] ~= r;
		size_t n;
		foreach (k; j["keys"])
		{
			if (++n > limit)
				break;
			if (auto rs = k.toString in byKey)
				foreach (r; *rs)
					if (!taken[r])
					{
						taken[r] = true;
						s.rows ~= r;
						break;
					}
		}
	}
	else if (j["rows"].type == Json.Type.array)
	{
		size_t n;
		foreach (r; j["rows"])
		{
			if (++n > limit)
				break;
			if (r.type != Json.Type.int_ || r.get!long < 0 || r.get!long >= d.length)
				continue;
			auto ri = cast(size_t) r.get!long;
			if (!taken[ri])
			{
				taken[ri] = true;
				s.rows ~= ri;
			}
		}
	}
	if (mode == "single-cell" || mode == "single-row")
		s.rows = s.rows.length ? s.rows[0 .. 1] : null;
	if (mode == "single-cell")
	{
		s.rows = null;
		if (j["cells"].type == Json.Type.array && j["cells"].length)
		{
			auto c = j["cells"][0];
			if (c.type == Json.Type.array && c.length == 2 && c[0].type == Json.Type.int_ && c[1].type == Json.Type.string)
			{
				auto r = c[0].get!long;
				if (r >= 0 && r < d.length && d.hasColumn(c[1].get!string))
					s.cells = [TableCell(cast(size_t) r, c[1].get!string)];
			}
		}
	}
	if (!multi && mode != "single-cell" && groupBy.length && j["group"].type == Json.Type.array && j["group"].length
		&& j["group"].length <= groupBy.length)
	{
		// a group path is valid when some row has those values
		string[] path;
		foreach (p; j["group"])
			path ~= p.type == Json.Type.string ? p.get!string : p.toString;
		foreach (r; 0 .. d.length)
		{
			bool all = true;
			foreach (i, g; path)
			{
				auto v = d.cell(r, d.colIndex(groupBy[i]));
				all = all && (v.type == Json.Type.string ? v.get!string : v.toString) == g;
			}
			if (all)
			{
				s.group = path;
				s.rows = null;
				break;
			}
		}
	}
	if (rowKey.length)
	{
		auto kc = d.colIndex(rowKey);
		foreach (r; s.rows)
			s.keys ~= d.cell(r, kc);
	}
	return s;
}

/// The selection as sent to the browser; `rows` is the frame's length (checked by `decodeSelection`
/// when there is no rowKey).
package Json selectionJson(const TableSelection s, size_t frameRows = size_t.max, bool keyed = false)
{
	auto j = Json.emptyObject;
	if (frameRows != size_t.max)
		j["n"] = cast(long) frameRows;
	// keyed tables keep the keys: on the next run the rows are found by them, so a selection never
	// moves to other rows when the frame changes (e.g. the selected rows were removed)
	if (keyed)
	{
		auto ks = Json.emptyArray;
		foreach (k; s.keys)
			ks.appendArrayElement(k);
		j["keys"] = ks;
	}
	auto rows = Json.emptyArray;
	foreach (r; s.rows)
		rows.appendArrayElement(Json(cast(long) r));
	j["rows"] = rows;
	auto cells = Json.emptyArray;
	foreach (c; s.cells)
		cells.appendArrayElement(Json([Json(cast(long) c.row), Json(c.column)]));
	j["cells"] = cells;
	auto g = Json.emptyArray;
	foreach (p; s.group)
		g.appendArrayElement(Json(p));
	j["group"] = g;
	return j;
}

/// Style tokens of the cells (`cellStyle`): `{"row,col": "bg:success bold", ...}`, only cells with
/// a style. `row` is the row of the frame passed in, `col` the column index in the shown frame.
package Json cellStylesJson(DataFrame d, string delegate(size_t row, string column, Json value) cellStyle)
{
	auto styles = Json.emptyObject;
	if (cellStyle is null)
		return styles;
	foreach (r; 0 .. d.length)
		foreach (c, n; d.columns)
		{
			auto s = cellStyle(r, n, d.cell(r, c));
			if (s.length)
				styles[r.to!string ~ "," ~ c.to!string] = s;
		}
	return styles;
}

/// The table JSON shared by `dataframe`, `table` and `dataEditor`: data, column config, totals,
/// cell styles.
package Json tableJson(DataFrame d, const ColumnConfig[string] columnConfig, const string[string] totals,
	string delegate(size_t, string, Json) cellStyle, string what)
{
	auto j = d.toJson();
	auto ct = columnConfigJson(d.columns, columnConfig, totals, what);
	if (ct["config"].length) j["config"] = ct["config"];
	if (ct["totals"].length) j["totals"] = ct["totals"];
	auto styles = cellStylesJson(d, cellStyle);
	if (styles.length) j["styles"] = styles;
	return j;
}

/// Data elements mixed into `St`.
mixin template DataElements()
{

	/// `st.dataframe` — interactive table: sort by clicking a header, search, CSV download.
	/// - `columnConfig`: per column label, format, width, tooltip, pinned/hidden, colours, grouped
	///   headers (see `ColumnConfig`);
	/// - `totals`: a row pinned at the bottom: per column `"sum"`, `"mean"`, `"min"`, `"max"`,
	///   `"count"` or a text such as `"Total"` (computed over the rows shown, after search);
	/// - `cellStyle`: style tokens per cell (`"bg:success"`, `"text:error"`, `"bold"`, `"bg:#fff3cd"`;
	///   several separated by spaces), or null;
	/// - `height`: fixed height in pixels; `maxHeight`: grow with the rows up to this height
	///   (default: 400 px).
	///
	/// Selection: with `onSelect: "rerun"` the table is a widget; clicking a row (or cell) reruns
	/// the app and returns the selection. `selectionMode`: `"single-row"` (click again to clear),
	/// `"multi-row"` (checkboxes, Shift-click for ranges) or `"single-cell"`. `rowKey` names a
	/// column whose values identify rows (`selection.keys`; the selection then survives
	/// filtering). Keyboard: ↑/↓ move between rows, Space or Enter selects.
	///
	/// Tree rows: `groupBy: ["manager", "supplier"]` groups the rows into levels that open and
	/// close (←/→ with the keyboard), with group values aggregated by `totals`; sorting keeps rows
	/// under their group. `expanded` levels are open at first.
	TableSelection dataframe(DataFrame df, int height = 0, bool hideIndex = false, bool useContainerWidth = true,
		string[] columnOrder = null, ColumnConfig[string] columnConfig = null, string[string] totals = null,
		string delegate(size_t row, string column, Json value) cellStyle = null, int maxHeight = 0,
		string onSelect = "ignore", string selectionMode = "single-row", string rowKey = null, string key = null,
		string[] groupBy = null, int expanded = 0, void delegate() onChange = null)
	{
		import std.algorithm : canFind;
		import std.array : join;
		if (onSelect != "ignore" && onSelect != "rerun")
			throw new StreamlitAPIException(`dataframe(): onSelect must be "ignore" or "rerun"`);
		if (!["single-row", "multi-row", "single-cell"].canFind(selectionMode))
			throw new StreamlitAPIException(`dataframe(): selectionMode must be "single-row", "multi-row" or "single-cell"`);
		auto d = columnOrder.length ? df.select(columnOrder) : df;
		if (rowKey.length && !d.hasColumn(rowKey))
			throw new StreamlitAPIException(`dataframe(): rowKey "` ~ rowKey ~ `" is not a column`);
		foreach (g; groupBy)
			if (!d.hasColumn(g))
				throw new StreamlitAPIException(`dataframe(): groupBy "` ~ g ~ `" is not a column`);
		auto j = tableJson(d, columnConfig, totals, cellStyle, "dataframe()");
		j["kind"] = "dataframe";
		j["height"] = height;
		j["maxHeight"] = maxHeight;
		j["hideIndex"] = hideIndex;
		j["fullWidth"] = useContainerWidth;
		if (groupBy.length)
		{
			j["groupBy"] = toJ(groupBy);
			j["expanded"] = expanded;
			j["treeKey"] = key.length ? key : (cast(string[]) d.columns.dup).join("\x01") ~ "|" ~ groupBy.join("\x01");
		}
		if (key.length)
			j["memoKey"] = "t:" ~ key; // the browser keeps the scroll position (and open groups) across reruns
		if (onSelect != "rerun")
		{
			emit(j);
			return TableSelection.init;
		}
		j["selectionMode"] = selectionMode;
		if (rowKey.length) j["rowKey"] = rowKey;
		// without a rowKey, a selection is only meaningful for the same rows: a new id when they change
		auto id = widgetId("dataframe", key, (cast(string[]) d.columns.dup).join("\x01"), selectionMode,
			rowKey.length ? rowKey : d.length.to!string, groupBy.join("\x01"));
		immutable n = rowKey.length ? size_t.max : d.length;
		return widget!TableSelection("dataframe", id, key, TableSelection.init, (TableSelection s) => selectionJson(s, n, rowKey.length > 0),
			(Json v) => decodeSelection(v, d, selectionMode, rowKey, groupBy), onChange, j);
	}

	/// `st.dataframe` for JSON records.
	void dataframe(Json records, int height = 0, bool hideIndex = false)
	{
		dataframe(DataFrame.fromJson(records), height, hideIndex);
	}

	/// `st.table` — static table (no sorting or scrolling); `columnConfig`, `totals` and
	/// `cellStyle` work as in `dataframe`.
	void table(DataFrame df, bool hideIndex = false, ColumnConfig[string] columnConfig = null,
		string[string] totals = null, string delegate(size_t row, string column, Json value) cellStyle = null)
	{
		auto j = tableJson(df, columnConfig, totals, cellStyle, "table()");
		j["kind"] = "table";
		j["hideIndex"] = hideIndex;
		emit(j);
	}

	/// `st.data_editor` — editable table; returns the edited frame.
	/// `numRows`: "fixed" or "dynamic" (allows adding/deleting rows). `columnConfig` chooses the
	/// editors (`ColumnConfig.select(options)` is a drop-down, `number` has min/max/step,
	/// `checkbox`, `date`, ...); edits it does not allow are dropped on the server too.
	/// `maxRows` (with `numRows: "dynamic"`) limits how many rows the table may have: "+ Add row"
	/// stops there, and rows added beyond it are ignored on the server (0 = no limit).
	DataFrame dataEditor(DataFrame df, string key = null, string numRows = "fixed", string[] disabled = null,
		bool hideIndex = false, int height = 0, void delegate() onChange = null, bool disabledAll = false,
		ColumnConfig[string] columnConfig = null, string[] columnOrder = null, size_t maxRows = 0)
	{
		import std.array : join;
		auto ct = columnConfigJson(df.columns, columnConfig, null, "dataEditor()");
		auto id = widgetId("data_editor", key, (cast(string[]) df.columns.dup).join(","), df.length.to!string);
		DataFrame result;
		auto state = widget!Json("data_editor", id, key, Json.emptyObject, (Json v) => v, (Json j) {
			if (j.type != Json.Type.object) throw new Exception("bad editor state");
			return j;
		}, onChange, Json.emptyObject, false, (Json st_) {
			long[] rowMap;
			result = applyEditorState(df, st_, rowMap, columnConfig, disabled, numRows == "dynamic" ? maxRows : 0);
			auto j = (columnOrder.length ? result.select(columnOrder) : result).toJson();
			if (ct["config"].length) j["config"] = ct["config"];
			j["rowMap"] = toJ(rowMap);
			j["numRows"] = numRows;
			j["maxRows"] = maxRows;
			j["disabledCols"] = toJ(disabled);
			j["disabled"] = disabledAll;
			j["hideIndex"] = hideIndex;
			j["height"] = height;
			return j;
		});
		return result;
	}
}

unittest
{
	auto df = new DataFrame;
	df.addColumn("a", [1, 2, 3]).addColumn("b", ["x", "y", "z"]);
	long[] map;
	auto st = parseJsonString(`{"edited":{"1":{"a":"20","b":"Y"}},"deleted":[0],"added":[{"a":4}]}`);
	auto r = applyEditorState(df, st, map);
	assert(r.length == 3);
	assert(r.column!long("a") == [20, 3, 4]);
	assert(r.column!string("b") == ["Y", "z", null]);
	assert(map == [1, 2, -1]);
}
