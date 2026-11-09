/// Tutorial app: a small sales dashboard. docs/tutorial.md builds it step by step.
import streamlitd;
import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.format : format;

// --- Step 2: load the data once; cached across reruns and sessions --------------------
DataFrame loadSales(string path)
{
	return DataFrame.readCsv(path);
}

void app(St st)
{
	// --- Step 8: page config, design style and color scheme--------------------------------------
	st.setPageConfig(title: "Sales dashboard", icon: "📈", layout: Layout.wide);
	auto design = st.sidebar.selectbox("Design style", designNames(), key: "design");
	auto scheme = st.sidebar.selectbox("Color scheme", colorSchemeNames(), key: "scheme");
	st.setTheme(scheme: scheme, design: design);

	// --- Step 1: text ------------------------------------------------------------------
	st.title("📈 Sales dashboard");
	st.caption("A streamlitd tutorial app. Every interaction reruns this function from the top.");

	// --- Step 2 + 6: cached CSV plus rows added through the form (kept in session state) --
	auto sales = cacheData!loadSales("data/sales.csv"); // a copy: safe to modify
	foreach (row; st.session.get!(Json[][])("added"))
		sales.appendRow(row);

	// --- Step 3: sidebar filters --------------------------------------------------------
	st.sidebar.header("Filters");
	auto regions = st.sidebar.multiselect("Regions", ["North", "South", "East", "West"],
		["North", "South", "East", "West"]);
	auto product = st.sidebar.pills("Product", ["Widget", "Gadget", "Gizmo"]);
	auto view = sales.filter((Row r) =>
		regions.canFind(r.get!string("region")) &&
		(product is null || r.get!string("product") == product));

	// --- Step 4: key metrics in columns ------------------------------------------------
	auto m = st.columns(3);
	m[0].metric("Revenue", format("$%,.0f", view.sum("revenue")));
	m[1].metric("Units sold", format("%,.0f", view.sum("units")));
	m[2].metric("Orders", cast(long) view.length);

	// --- Step 5: table and charts in tabs ----------------------------------------------
	auto tabs = st.tabs(["📊 Charts", "🗂 Data"]);
	with (tabs[0])
	{
		auto c = columns(2);
		c[0].subheader("Revenue over time");
		c[0].lineChart(view.groupBy("date", ["revenue"], "sum"), x: "date", height: 280);
		c[1].subheader("Units by region");
		c[1].barChart(view.groupBy("region", ["units"], "sum"), x: "region", height: 280);
	}
	with (tabs[1])
	{
		dataframe(view.sortBy("date", false), height: 320);
		downloadButton("Download CSV", view.toCsv(), "sales.csv", "text/csv");
	}

	// --- Step 6: a form that adds a row --------------------------------------------------
	with (st.expander("➕ Add a sale"))
	{
		auto f = form("add_sale", clearOnSubmit: true);
		auto day = f.dateInput("Date", Date(2024, 3, 31));
		auto region = f.selectbox("Region", ["North", "South", "East", "West"]);
		auto prod = f.selectbox("Product", ["Widget", "Gadget", "Gizmo"]);
		auto units = f.numberInput("Units", 10, minValue: 1);
		auto price = f.numberInput("Price", 12.5, minValue: 0, step: 0.5);
		if (f.formSubmitButton("Add", type: "primary"))
		{
			auto added = st.session.get!(Json[][])("added");
			added ~= [Json(day.toISOExtString), Json(region), Json(prod), Json(cast(long) units), Json(units * price)];
			st.session["added"] = added;
			st.toast(format("Added %d × %s", units, prod), icon: "✅");
			st.rerun();
		}
	}

	// --- Step 7: a live fragment that refreshes itself every 2 seconds -------------------
	st.fragment((St f) {
		auto ticks = st.session.get!int("ticks") + 1;
		st.session["ticks"] = ticks;
		f.metric("Live orders today", 40 + ticks, "+1");
	}, runEvery: 2);
}

mixin StreamlitMain!app;
