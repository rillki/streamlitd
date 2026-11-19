/// Charts rendered with Vega-Lite (bundled).
module streamlitd.charts;

import std.algorithm : canFind, map, filter;
import std.array : array, replace, join;
import vibe.data.json;

import streamlitd.dataframe;
import streamlitd.util;

/// Name of the synthetic index field used when `x` is not given.
enum indexField = "(index)";

/// Escape a field name for Vega-Lite field references.
string vlField(string name)
{
	return name.replace(`\`, `\\`).replace(".", `\.`).replace("[", `\[`).replace("]", `\]`);
}

private string vlType(ColumnType t, string mark)
{
	final switch (t)
	{
		case ColumnType.integer:
		case ColumnType.number:
			return mark == "bar" ? "ordinal" : "quantitative";
		case ColumnType.date:
		case ColumnType.datetime:
			return "temporal";
		case ColumnType.boolean:
		case ColumnType.text:
		case ColumnType.object:
			return "nominal";
	}
}

/// Build a Vega-Lite spec for the simple chart elements.
Json buildChartSpec(string mark, DataFrame df, string x, string[] y, string color, int height,
	string xLabel, string yLabel, bool stack = true, bool horizontal = false, string size = null)
{
	// data as records, with an index column when x is not given
	auto values = df.toRecords();
	string xf = x;
	ColumnType xt = ColumnType.integer;
	if (xf.length == 0)
	{
		xf = indexField;
		foreach (size_t i, ref Json r; values)
			r[indexField] = i;
	}
	else
		xt = df.typeOf(xf);

	if (y.length == 0)
		y = df.columns.filter!(c => c != x && c != color &&
			(df.typeOf(c) == ColumnType.integer || df.typeOf(c) == ColumnType.number)).array.dup;

	string xType = xf == indexField ? (mark == "bar" ? "ordinal" : "quantitative") : vlType(xt, mark);

	auto enc = Json.emptyObject;
	auto xEnc = jo("field", vlField(xf), "type", xType, "title", xLabel.length ? xLabel : (xf == indexField ? null : xf));
	if (xType == "nominal" || xType == "ordinal")
		xEnc["sort"] = Json(null);
	// times within a day (a live chart's last minutes): clock labels, not Vega's ".800"-style ticks
	if (xt == ColumnType.datetime && xf != indexField && df.length)
	{
		import std.algorithm : maxElement, minElement;
		auto ts = df.rawColumn(xf).filter!(j => j.type == Json.Type.string).map!(j => j.get!string)
			.filter!(v => v.length >= 10).array;
		if (ts.length && ts.maxElement[0 .. 10] == ts.minElement[0 .. 10])
			xEnc["axis"] = jo("format", "%H:%M:%S", "labelOverlap", true);
	}
	auto transforms = Json.emptyArray;
	Json yEnc;
	bool multi = color.length == 0 && y.length > 1;
	if (multi)
	{
		transforms ~= jo("fold", y.map!(c => vlField(c)).array, "as", ["series", "value"]);
		yEnc = jo("field", "value", "type", "quantitative", "title", yLabel.length ? yLabel : null);
		enc["color"] = jo("field", "series", "type", "nominal", "title", null, "sort", y);
	}
	else
	{
		string yf = y.length ? y[0] : "value";
		yEnc = jo("field", vlField(yf), "type", "quantitative", "title", yLabel.length ? yLabel : yf);
		if (color.length)
		{
			if (color.length && color[0] == '#')
				enc["color"] = jo("value", color);
			else
				enc["color"] = jo("field", vlField(color), "type", "nominal", "title", color);
		}
	}
	if (mark == "area" || mark == "bar")
		yEnc["stack"] = stack ? Json("zero") : Json(null);
	if (horizontal)
	{
		enc["y"] = xEnc;
		enc["x"] = yEnc;
	}
	else
	{
		enc["x"] = xEnc;
		enc["y"] = yEnc;
	}
	// unstacked bars of several series stand side by side (like Streamlit's stack=False)
	if (mark == "bar" && !stack && "color" in enc && "field" in enc["color"])
	{
		auto off = jo("field", enc["color"]["field"], "type", "nominal");
		if ("sort" in enc["color"])
			off["sort"] = enc["color"]["sort"];
		enc[horizontal ? "yOffset" : "xOffset"] = off;
	}
	if (size.length)
		enc["size"] = jo("field", vlField(size), "type", "quantitative", "title", size);

	auto tooltip = Json.emptyArray;
	tooltip ~= xEnc;
	if (multi)
	{
		tooltip ~= jo("field", "series", "type", "nominal", "title", "series");
		tooltip ~= jo("field", "value", "type", "quantitative", "title", "value");
	}
	else
		tooltip ~= yEnc;
	enc["tooltip"] = tooltip;

	Json markJ;
	if (mark == "line")
		markJ = jo("type", "line", "point", false);
	else if (mark == "area")
		markJ = jo("type", "area", "line", true, "opacity", 0.6);
	else if (mark == "point")
		markJ = jo("type", "circle", "size", 60);
	else
		markJ = jo("type", mark);

	auto spec = jo(
		"$schema", "https://vega.github.io/schema/vega-lite/v5.json",
		"width", "container",
		"height", height > 0 ? height : 350,
		"data", jo("values", values),
		"mark", markJ,
		"encoding", enc);
	if (transforms.length)
		spec["transform"] = transforms;
	if (mark == "line" || mark == "point")
		spec["params"] = [jo("name", "grid", "select", "interval", "bind", "scales")];
	return spec;
}

/// Chart elements mixed into `St`.
mixin template Charts()
{

	private void chartImpl(string mark, DataFrame df, string x, string[] y, string color, int height,
		string xLabel, string yLabel, bool stack, bool horizontal, bool useContainerWidth, string size = null)
	{
		auto spec = buildChartSpec(mark, df, x, y, color, height, xLabel, yLabel, stack, horizontal, size);
		if (!useContainerWidth)
			spec.remove("width");
		emit(jo("kind", "vega_lite", "spec", spec, "fullWidth", useContainerWidth));
	}

	/// `st.line_chart`
	void lineChart(DataFrame df, string x = null, string[] y = null, string color = null, int height = 0,
		string xLabel = null, string yLabel = null, bool useContainerWidth = true)
	{
		chartImpl("line", df, x, y, color, height, xLabel, yLabel, false, false, useContainerWidth);
	}

	/// `st.area_chart`
	void areaChart(DataFrame df, string x = null, string[] y = null, string color = null, int height = 0,
		string xLabel = null, string yLabel = null, bool stack = true, bool useContainerWidth = true)
	{
		chartImpl("area", df, x, y, color, height, xLabel, yLabel, stack, false, useContainerWidth);
	}

	/// `st.bar_chart`
	void barChart(DataFrame df, string x = null, string[] y = null, string color = null, int height = 0,
		string xLabel = null, string yLabel = null, bool stack = true, bool horizontal = false,
		bool useContainerWidth = true)
	{
		chartImpl("bar", df, x, y, color, height, xLabel, yLabel, stack, horizontal, useContainerWidth);
	}

	/// `st.scatter_chart`
	void scatterChart(DataFrame df, string x = null, string[] y = null, string color = null, string size = null,
		int height = 0, string xLabel = null, string yLabel = null, bool useContainerWidth = true)
	{
		chartImpl("point", df, x, y, color, height, xLabel, yLabel, false, false, useContainerWidth, size);
	}

	/// `st.vega_lite_chart` — any Vega-Lite spec; if `data` is given it becomes the spec's data.
	void vegaLiteChart(Json spec, DataFrame data = null, bool useContainerWidth = true)
	{
		auto s = spec.clone;
		if (data !is null)
			s["data"] = jo("values", data.toRecords());
		if (useContainerWidth && s["width"].type == Json.Type.undefined)
			s["width"] = "container";
		emit(jo("kind", "vega_lite", "spec", s, "fullWidth", useContainerWidth));
	}

	/// ditto, spec as JSON text.
	void vegaLiteChart(string spec, DataFrame data = null, bool useContainerWidth = true)
	{
		vegaLiteChart(parseJsonString(spec), data, useContainerWidth);
	}

	/// `st.map` — points on an interactive map (Leaflet). Latitude/longitude columns are detected
	/// automatically (`lat`/`latitude`, `lon`/`lng`/`longitude`) unless named. `size` names a column
	/// with the radius in meters (or use `radius` for all points); `color` is a hex color or a column
	/// with hex colors. Tiles come from OpenStreetMap unless `[map] tileUrl` is configured.
	void map(DataFrame df, string latitude = null, string longitude = null, string size = null,
		double radius = 0, string color = null, double zoom = -1, int height = 400, bool useContainerWidth = true)
	{
		import streamlitd.errors : StreamlitAPIException;
		import std.algorithm : canFind;
		import std.uni : toLower;
		string pick(string given, string[] names)
		{
			if (given.length)
				return given;
			foreach (c; df.columns)
				if (names.canFind(c.toLower))
					return c;
			return null;
		}
		auto lat = pick(latitude, ["lat", "latitude"]);
		auto lon = pick(longitude, ["lon", "lng", "long", "longitude"]);
		if (lat is null || lon is null)
			throw new StreamlitAPIException("map() needs latitude/longitude columns (e.g. 'lat' and 'lon'); found: "
				~ (cast(string[]) df.columns.dup).join(", "));
		bool colorCol = color.length && color[0] != '#' && df.hasColumn(color);
		auto pts = Json.emptyArray;
		foreach (r; df)
		{
			auto la = r[lat], lo = r[lon];
			if (la.type == Json.Type.null_ || lo.type == Json.Type.null_)
				continue;
			auto p = jo("lat", r.get!double(lat), "lon", r.get!double(lon));
			if (size.length)
				p["size"] = r.get!double(size);
			if (colorCol)
				p["color"] = r.get!string(color);
			pts ~= p;
		}
		emit(jo("kind", "map", "points", pts, "radius", radius, "color", colorCol ? null : color, "zoom", zoom,
			"height", height, "fullWidth", useContainerWidth, "tileUrl", sess.mapTileUrl,
			"attribution", sess.mapAttribution));
	}

	/// `st.plotly_chart` — renders a Plotly figure (`{"data": [...], "layout": {...}}`, e.g. from
	/// `fig.to_json()` in Python or built in D). `theme: "streamlit"` applies the active design style;
	/// pass `null` for Plotly's own look. With `onSelect: "rerun"` the chart acts as a widget and
	/// returns the current selection (`{"points": [...]}`, or null).
	Json plotlyChart(Json figure, bool useContainerWidth = true, string theme = "streamlit", int height = 0,
		string key = null, string onSelect = "ignore")
	{
		auto fig = figure.clone;
		if (fig["data"].type == Json.Type.undefined)
			fig["data"] = Json.emptyArray;
		if (fig["layout"].type != Json.Type.object)
			fig["layout"] = Json.emptyObject;
		auto props = jo("figure", fig, "fullWidth", useContainerWidth, "theme", theme, "height", height,
			"selectable", onSelect == "rerun");
		if (onSelect != "rerun")
		{
			props["kind"] = "plotly";
			emit(props);
			return Json.undefined;
		}
		auto id = widgetId("plotly", key, fig["data"].toString);
		return widget!Json("plotly", id, key, Json(null), (Json v) => v, (Json j) => j, null, props);
	}

	/// ditto, figure as JSON text.
	Json plotlyChart(string figureJson, bool useContainerWidth = true, string theme = "streamlit", int height = 0,
		string key = null, string onSelect = "ignore")
	{
		return plotlyChart(parseJsonString(figureJson), useContainerWidth, theme, height, key, onSelect);
	}
}

unittest
{
	auto df = new DataFrame;
	df.addColumn("day", [1, 2, 3]).addColumn("a.b", [1.0, 2, 3]).addColumn("c", [3, 2, 1]);
	auto s = buildChartSpec("line", df, "day", null, null, 0, null, null);
	assert(s["transform"][0]["fold"].length == 2);
	assert(s["transform"][0]["fold"][0].get!string == `a\.b`);
	assert(s["encoding"]["x"]["field"].get!string == "day");
	assert(s["data"]["values"].length == 3);
	auto b = buildChartSpec("bar", df, null, ["c"], null, 200, null, null);
	assert(b["encoding"]["x"]["field"].get!string == "(index)");
	assert(b["height"].get!long == 200);
	assert(b["transform"].type == Json.Type.undefined);
	// unstacked bars of several series: side by side (xOffset), stacked ones: none
	auto g = buildChartSpec("bar", df, "day", ["a.b", "c"], null, 0, null, null, false);
	assert(g["encoding"]["xOffset"]["field"].get!string == "series");
	assert("xOffset" !in buildChartSpec("bar", df, "day", ["a.b", "c"], null, 0, null, null, true)["encoding"]);
	// a datetime x within one day: clock labels
	import std.datetime : DateTime;
	auto live = new DataFrame().addColumn("t", [DateTime(2026, 11, 18, 9, 0, 0), DateTime(2026, 11, 18, 9, 0, 5)])
		.addColumn("v", [1.0, 2]);
	assert(buildChartSpec("line", live, "t", ["v"], null, 0, null, null)["encoding"]["x"]["axis"]["format"].get!string == "%H:%M:%S");
	auto days_ = new DataFrame().addColumn("t", [DateTime(2026, 11, 18, 9, 0, 0), DateTime(2026, 11, 20, 9, 0, 0)])
		.addColumn("v", [1.0, 2]);
	assert("axis" !in buildChartSpec("line", days_, "t", ["v"], null, 0, null, null)["encoding"]["x"]);
	auto h = buildChartSpec("bar", df, "day", ["c"], "a.b", 0, null, null, false, true);
	assert(h["encoding"]["yOffset"]["field"].get!string == `a\.b`);
}
