/// `st.calendarGrid`: rows × days (or weeks) with markers and spans, e.g. a delivery or payment
/// schedule per supplier (streamlitd only).
module streamlitd.calendar;

import std.datetime : Date;
import std.math : isNaN;
import vibe.data.json;

/// A row of `st.calendarGrid`. Rows with a `parent` are shown under it, when it is opened.
struct GridRow
{
	string id;
	string label;
	string parent;            /// id of the row this one belongs to (null: a top row)
	string summary;           /// text in the summary column, e.g. "8 / 12 delivered"
	double progress = double.nan;  /// 0..1: a bar in the summary column
	double expected = double.nan;  /// 0..1: a mark on that bar ("expected by today")
}

/// An item on the grid: a marker on one day, or a span from `start` to `end`.
struct GridItem
{
	string id;          /// returned when clicked
	string row;         /// id of its row
	Date start;
	Date end;           /// Date.init: a marker on `start`; else a span (both days included)
	string label;       /// tooltip and accessible name, e.g. "Invoice 42 · 1,200 €"
	double value = double.nan;  /// sizes markers relative to the largest value (NaN: medium)
	string shape;       /// "dot" (default), "square" or "diamond"
	string color;       /// a token ("success", "warning", "error", "info", "muted", "primary"), a hex colour, or null (primary)
	bool outline;       /// hollow marker (e.g. planned rather than done)
}

/// What was clicked in a `st.calendarGrid` (on the run triggered by the click only).
struct GridEvent
{
	string kind;    /// "item", "row" or "cell"; null when nothing was clicked in this run
	string item;    /// the item's id (kind "item")
	string row;     /// the row's id (all kinds)
	Date date;      /// the clicked day (kind "item" and "cell")

	/// Did something get clicked in this run?
	bool opCast(T : bool)() const { return kind.length > 0; }
}

package Json calendarJson(GridRow[] rows, GridItem[] items, Date start, Date end, string unit, Date today)
{
	import streamlitd.errors : StreamlitAPIException;
	import streamlitd.util : jo;
	if (end < start)
		throw new StreamlitAPIException("calendarGrid(): end is before start");
	if (unit != "day" && unit != "week")
		throw new StreamlitAPIException(`calendarGrid(): unit must be "day" or "week"`);
	if ((end - start).total!"days" > 3700)
		throw new StreamlitAPIException("calendarGrid(): at most about ten years");
	bool[string] ids;
	foreach (r; rows)
	{
		if (r.id in ids)
			throw new StreamlitAPIException(`calendarGrid(): duplicate row id "` ~ r.id ~ `"`);
		ids[r.id] = true;
	}
	auto jr = Json.emptyArray;
	foreach (r; rows)
	{
		if (r.parent.length && r.parent !in ids)
			throw new StreamlitAPIException(`calendarGrid(): row "` ~ r.id ~ `" has an unknown parent "` ~ r.parent ~ `"`);
		auto o = jo("id", r.id, "label", r.label, "parent", r.parent, "summary", r.summary);
		if (!isNaN(r.progress)) o["progress"] = r.progress;
		if (!isNaN(r.expected)) o["expected"] = r.expected;
		jr.appendArrayElement(o);
	}
	auto ji = Json.emptyArray;
	foreach (it; items)
	{
		if (it.row !in ids)
			throw new StreamlitAPIException(`calendarGrid(): item "` ~ it.id ~ `" is on an unknown row "` ~ it.row ~ `"`);
		if (it.shape.length && it.shape != "dot" && it.shape != "square" && it.shape != "diamond")
			throw new StreamlitAPIException(`calendarGrid(): shape must be "dot", "square" or "diamond"`);
		auto o = jo("id", it.id, "row", it.row, "start", it.start.toISOExtString, "label", it.label,
			"shape", it.shape.length ? it.shape : "dot", "color", it.color, "outline", it.outline);
		if (it.end != Date.init)
		{
			if (it.end < it.start)
				throw new StreamlitAPIException(`calendarGrid(): item "` ~ it.id ~ `" ends before it starts`);
			o["end"] = it.end.toISOExtString;
		}
		if (!isNaN(it.value)) o["value"] = it.value;
		ji.appendArrayElement(o);
	}
	return jo("rows", jr, "items", ji, "start", start.toISOExtString, "end", end.toISOExtString, "unit", unit,
		"today", today.toISOExtString);
}

/// Decode a click event from the browser; unknown items, rows or dates make it empty.
package GridEvent decodeGridEvent(Json j, GridRow[] rows, GridItem[] items, Date start, Date end)
{
	GridEvent e;
	if (j.type != Json.Type.object)
		return e;
	auto kind = j["kind"].opt!string(null);
	auto row = j["row"].opt!string(null);
	bool rowOk;
	foreach (r; rows)
		rowOk = rowOk || r.id == row;
	if (!rowOk)
		return e;
	Date d;
	if (j["date"].type == Json.Type.string)
	{
		try
			d = Date.fromISOExtString(j["date"].get!string);
		catch (Exception)
			return e;
		if (d < start || d > end)
			return e;
	}
	switch (kind)
	{
		case "item":
			auto id = j["item"].opt!string(null);
			foreach (it; items)
				if (it.id == id && it.row == row)
					return GridEvent("item", id, row, d == Date.init ? it.start : d);
			return e;
		case "row":
			return GridEvent("row", null, row, Date.init);
		case "cell":
			if (d == Date.init)
				return e;
			return GridEvent("cell", null, row, d);
		default:
			return e;
	}
}

/// `st.calendarGrid`, mixed into `St`.
mixin template CalendarElements()
{
	/// A calendar grid (streamlitd only): one row per `GridRow` (rows with a `parent` open under
	/// it), one column per day (or week) from `start` to `end`, with markers and spans. Weekends,
	/// today and month starts are marked. Clicking an item, a row name or an empty day reruns the
	/// app and returns a `GridEvent` (like a button: only in that run). `focus` scrolls to an
	/// item and highlights it once. Keyboard: arrows move between items, Enter opens.
	/// ---
	/// auto ev = st.calendarGrid(rows, items, Date(2026, 11, 1), Date(2026, 12, 31), key: "plan");
	/// if (ev.kind == "item") st.dialog("Delivery", (St d) { d.write(ev.item); });
	/// ---
	GridEvent calendarGrid(GridRow[] rows, GridItem[] items, Date start, Date end, string unit = "day",
		string key = null, string focus = null, int height = 0, Date today = Date.init, string summaryLabel = null,
		int expanded = 0)
	{
		import std.datetime : Clock;
		import streamlitd.calendar : calendarJson, decodeGridEvent;
		if (today == Date.init)
			today = cast(Date) Clock.currTime();
		auto p = calendarJson(rows, items, start, end, unit, today);
		p["focus"] = focus;
		p["height"] = height;
		p["summaryLabel"] = summaryLabel;
		p["expanded"] = expanded;
		auto id = widgetId("calendar_grid", key, start.toISOExtString, end.toISOExtString, unit);
		p["memoKey"] = id;
		return widget!GridEvent("calendar_grid", id, key, GridEvent.init, (GridEvent v) => Json(null),
			(Json j) => decodeGridEvent(j, rows, items, start, end), null, p, true);
	}
}

unittest
{
	auto rows = [GridRow("acme", "ACME"), GridRow("rocket", "Rocket", "acme")];
	auto items = [GridItem("i1", "rocket", Date(2026, 1, 5), Date.init, "Invoice", 100)];
	auto j = calendarJson(rows, items, Date(2026, 1, 1), Date(2026, 1, 31), "day", Date(2026, 1, 10));
	assert(j["rows"][1]["parent"].get!string == "acme" && j["items"][0]["start"].get!string == "2026-01-05");
	import std.exception : assertThrown;
	assertThrown(calendarJson([GridRow("a", "A", "nope")], null, Date(2026, 1, 1), Date(2026, 1, 2), "day", Date.init));
	assertThrown(calendarJson(rows, [GridItem("x", "zz", Date(2026, 1, 1))], Date(2026, 1, 1), Date(2026, 1, 2), "day", Date.init));
	assertThrown(calendarJson(rows, null, Date(2026, 1, 2), Date(2026, 1, 1), "day", Date.init));
	auto ev = decodeGridEvent(parseJsonString(`{"kind": "item", "item": "i1", "row": "rocket"}`), rows, items,
		Date(2026, 1, 1), Date(2026, 1, 31));
	assert(ev.kind == "item" && ev.date == Date(2026, 1, 5) && cast(bool) ev);
	assert(!decodeGridEvent(parseJsonString(`{"kind": "item", "item": "i1", "row": "acme"}`), rows, items,
		Date(2026, 1, 1), Date(2026, 1, 31)));
	auto cell = decodeGridEvent(parseJsonString(`{"kind": "cell", "row": "acme", "date": "2026-01-20"}`), rows, items,
		Date(2026, 1, 1), Date(2026, 1, 31));
	assert(cell.kind == "cell" && cell.date == Date(2026, 1, 20));
	assert(!decodeGridEvent(parseJsonString(`{"kind": "cell", "row": "acme", "date": "2027-01-20"}`), rows, items,
		Date(2026, 1, 1), Date(2026, 1, 31)));
}
