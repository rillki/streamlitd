/// DataFrame display and editing elements.
module streamlitd.dataelements;

import std.conv : to;
import vibe.data.json;

import streamlitd.dataframe;
import streamlitd.util;

/// Apply a data_editor state (`{edited, added, deleted}`) to a frame.
/// Returns the resulting frame and fills `rowMap` with the source of each output row
/// (original row index, or `-(k+1)` for the k-th added row).
DataFrame applyEditorState(DataFrame src, Json state, out long[] rowMap)
{
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
					if (df.hasColumn(c))
						df.setCell(ri, c, coerceCell(v, df.typeOf(c)));
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
			Json[] row;
			foreach (ci, n; df.columns)
			{
				auto v = a.type == Json.Type.object ? a[n] : Json.undefined;
				row ~= v.type == Json.Type.undefined ? Json(null) : coerceCell(v, df.types[ci]);
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

/// Data elements mixed into `St`.
mixin template DataElements()
{

	/// `st.dataframe` — interactive (sortable, scrollable) table.
	void dataframe(DataFrame df, int height = 0, bool hideIndex = false, bool useContainerWidth = true,
		string[] columnOrder = null)
	{
		auto d = columnOrder.length ? df.select(columnOrder) : df;
		auto j = d.toJson();
		j["kind"] = "dataframe";
		j["height"] = height;
		j["hideIndex"] = hideIndex;
		j["fullWidth"] = useContainerWidth;
		emit(j);
	}

	/// `st.dataframe` for JSON records.
	void dataframe(Json records, int height = 0, bool hideIndex = false)
	{
		dataframe(DataFrame.fromJson(records), height, hideIndex);
	}

	/// `st.table` — static table.
	void table(DataFrame df, bool hideIndex = false)
	{
		auto j = df.toJson();
		j["kind"] = "table";
		j["hideIndex"] = hideIndex;
		emit(j);
	}

	/// `st.data_editor` — editable table; returns the edited frame.
	/// `numRows`: "fixed" or "dynamic" (allows adding/deleting rows).
	DataFrame dataEditor(DataFrame df, string key = null, string numRows = "fixed", string[] disabled = null,
		bool hideIndex = false, int height = 0, void delegate() onChange = null, bool disabledAll = false)
	{
		auto id = widgetId("data_editor", key, (cast(string[]) df.columns.dup).join(","), df.length.to!string);
		DataFrame result;
		auto state = widget!Json("data_editor", id, key, Json.emptyObject, (Json v) => v, (Json j) {
			if (j.type != Json.Type.object) throw new Exception("bad editor state");
			return j;
		}, onChange, Json.emptyObject, false, (Json st_) {
			long[] rowMap;
			result = applyEditorState(df, st_, rowMap);
			auto j = result.toJson();
			j["rowMap"] = toJ(rowMap);
			j["numRows"] = numRows;
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
