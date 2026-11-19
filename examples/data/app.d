/// DataFrames, charts, files, media and caching.
import streamlitd;
import std.conv : to;
import std.format : format;
import std.math : sin, cos;
import std.algorithm : map;
import std.array : array, join;
import std.range : iota;

struct Sale { string region; string product; int units; double revenue; }

// expensive computation cached across reruns and sessions
DataFrame loadSales(int n)
{
	auto regions = ["North", "South", "East", "West"];
	auto products = ["Widget", "Gadget", "Doohickey"];
	Sale[] rows;
	foreach (i; 0 .. n)
		rows ~= Sale(regions[i % 4], products[i % 3], 10 + (i * 7) % 40, 100.0 + (i * 37) % 500);
	return DataFrame.fromStructs(rows);
}

DataFrame waves(int points)
{
	auto x = iota(points).map!(i => i * 0.2).array;
	return new DataFrame()
		.addColumn("x", x)
		.addColumn("sin", x.map!(v => sin(v)).array)
		.addColumn("cos", x.map!(v => cos(v)).array);
}

void app(St st)
{
	st.setPageConfig(title: "Data", icon: "📊", layout: Layout.wide);
	st.title("Data & charts");

	auto df = cacheData!loadSales(24);
	auto region = st.sidebar.multiselect("Regions", ["North", "South", "East", "West"], ["North", "South", "East", "West"]);
	auto filtered = df.filter((Row r) {
		foreach (x; region)
			if (x == r.get!string("region"))
				return true;
		return false;
	});

	auto m = st.columns(3);
	m[0].metric("Rows", cast(long) filtered.length);
	m[1].metric("Units", format("%.0f", filtered.sum("units")));
	m[2].metric("Revenue", format("$%.2f", filtered.sum("revenue")));

	st.subheader("st.dataframe");
	st.dataframe(filtered, height: 250);

	st.subheader("Column configuration, totals and colours");
	alias C = ColumnConfig;
	auto report = new DataFrame()
		.addColumn("region", ["North", "South", "East", "West"])
		.addColumn("units", [120, 95, 143, 88])
		.addColumn("revenue", [12_500.5, 9_800.0, 15_230.25, 7_100.0])
		.addColumn("share", [28.0, 22.0, 34.0, 16.0])
		.addColumn("change", [13.6, -5.8, 16.3, -4.1])
		.addColumn("target", [80, 65, 95, 50])
		.addColumn("updated", ["2026-11-02", "2026-11-05", "2026-11-04", "2026-10-30"])
		.addColumn("site", ["https://example.com/north", "https://example.com/south", "https://example.com/east",
			"https://example.com/west"]);
	st.dataframe(report, hideIndex: true, columnConfig: [
		"region": C.text("Region", pinned: true),
		"units": C.number("Units", format: "%d", group: "This month"),
		"revenue": C.number("Revenue", format: "%,.0f", background: "heat", detailColumn: "share", group: "This month"),
		"share": C.number(format: "%.0f%% of total", hidden: true),
		"change": C.number("Change", format: "%+.1f%%", color: "sign", help: "Compared with last month", group: "This month"),
		"target": C.progress("Target reached", min: 0, max: 100, format: "%d%%"),
		"updated": C.date("Updated", format: "DD.MM.YYYY"),
		"site": C.link("Site", displayText: "Open"),
	], totals: ["region": "Total", "units": "sum", "revenue": "sum", "change": "mean"],
		cellStyle: (size_t row, string col, Json v) => col == "units" && v.get!long < 100 ? "bg:warning" : null);

	st.subheader("Selection and tree rows");
	auto brands = new DataFrame()
		.addColumn("manager", ["Ann", "Ann", "Ann", "Bob", "Bob"])
		.addColumn("supplier", ["ACME", "ACME", "Globex", "Initech", "Initech"])
		.addColumn("brand", ["Rocket", "Anvil", "Gizmo", "Stapler", "Printer"])
		.addColumn("orders", [12, 7, 9, 4, 11])
		.addColumn("amount", [1_200.0, 650.0, 980.0, 210.0, 1_500.0])
		.addColumn("id", ["b1", "b2", "b3", "b4", "b5"]);
	// a tree: manager › supplier › brand, with sums per group; click a row to select it
	auto pick = st.dataframe(brands, hideIndex: true, groupBy: ["manager", "supplier"], expanded: 1,
		totals: ["brand": "Total", "orders": "sum", "amount": "sum"], onSelect: "rerun", rowKey: "id", key: "brands",
		columnConfig: ["id": C.hide(), "brand": C.text("Brand"), "amount": C.number("Amount", format: "%,.0f")]);
	if (pick.keys.length)
		st.write("Selected brand:", pick.keys[0].get!string);
	else if (pick.group.length)
		st.write("Selected group:", pick.group.join(" › "));
	else
		st.caption("Click a brand or a group.");
	// several rows (checkboxes, Shift-click for a range)
	auto many = st.dataframe(df.head(6), height: 260, onSelect: "rerun", selectionMode: "multi-row", key: "multi");
	st.write("Selected rows:", many.rows.to!string);

	st.subheader("Charts");
	auto c = st.columns(2);
	c[0].barChart(filtered.groupBy("region", ["units", "revenue"], "sum"), x: "region", y: ["units"]);
	c[1].lineChart(cacheData!waves(60), x: "x", y: ["sin", "cos"]);
	auto c2 = st.columns(2);
	c2[0].areaChart(cacheData!waves(60), x: "x");
	c2[1].scatterChart(filtered, x: "units", y: ["revenue"], color: "product");
	st.vegaLiteChart(`{"mark": {"type": "arc", "innerRadius": 50}, "encoding": {"theta": {"field": "revenue", "aggregate": "sum", "type": "quantitative"}, "color": {"field": "product", "type": "nominal"}}, "height": 250}`, filtered);

	st.subheader("st.data_editor");
	auto todo = new DataFrame()
		.addColumn("task", ["Write D code", "Run tests", "Ship it"])
		.addColumn("done", [true, false, false])
		.addColumn("hours", [3, 1, 2]);
	todo.addColumn("priority", ["high", "normal", "low"]);
	auto edited = st.dataEditor(todo, numRows: "dynamic", key: "todo", columnConfig: [
		"task": ColumnConfig.text("Task", required: true),
		"hours": ColumnConfig.number("Hours", min: 0, max: 24, step: 1),
		"priority": ColumnConfig.select("Priority", ["high", "normal", "low"], required: true),
	]);
	st.write(format("Total hours: **%.0f**, done: **%d/%d**", edited.sum("hours"),
		edited.filter(r => r.get!bool("done")).length, edited.length));

	st.subheader("st.table");
	st.table(df.head(3));

	st.subheader("Files");
	auto up = st.fileUploader("Upload a CSV", ["csv", "txt"]);
	if (up !is null)
	{
		st.write(format("Uploaded **%s** (%d bytes)", up.name, up.size));
		try
		{
			auto u = DataFrame.fromCsv(up.text);
			st.dataframe(u);
		}
		catch (Exception e)
			st.error("Could not parse CSV: " ~ e.msg);
	}
	if (st.downloadButton("Download sales CSV", filtered.toCsv(), "sales.csv", "text/csv"))
		st.toast("Download started");

	st.subheader("st.image");
	st.image(svgLogo(), caption: "An SVG generated in D", width: 160);

	st.subheader("st.json");
	st.json(`{"name": "streamlitd", "features": ["widgets", "charts", "dataframes"], "nested": {"ok": true}}`);
}

const(ubyte)[] svgLogo()
{
	return cast(const(ubyte)[]) `<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80" viewBox="0 0 160 80">
<rect width="160" height="80" rx="12" fill="#ff4b4b"/><text x="80" y="52" font-size="32" text-anchor="middle" fill="white" font-family="sans-serif">D ❤ st</text></svg>`;
}

mixin StreamlitMain!app;
