/// LaTeX, code highlighting, Plotly, maps and custom components.
import streamlitd;
import std.conv : to;
import std.format : format;

__gshared Component counter;

shared static this()
{
	counter = declareComponent("counter", path: "counter");
}

void app(St st)
{
	st.setPageConfig(title: "Extras", icon: "🧪", layout: Layout.wide);
	st.title("Extras");

	auto t = st.tabs(["Math & code", "Plotly", "Map", "Components"]);
	with (t[0])
	{
		latex(`e^{i\pi} + 1 = 0`);
		markdown(`Inline math $a^2 + b^2 = c^2$ costs $5, and display math:
$$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$`);
		code("import std.stdio;\n\nvoid main()\n{\n    // comment\n    writeln(\"Hello, \", 42);\n}", "d", lineNumbers: true);
		code("def greet(name: str) -> str:\n    return f\"Hello {name}\"", "python");
	}
	with (t[1])
	{
		auto sel = plotlyChart(`{
			"data": [
				{"type": "scatter", "mode": "markers", "name": "A", "x": [1, 2, 3, 4], "y": [10, 15, 13, 17]},
				{"type": "bar", "name": "B", "x": [1, 2, 3, 4], "y": [16, 5, 11, 9]}
			],
			"layout": {"title": {"text": "Plotly in D"}}
		}`, key: "plt", onSelect: "rerun");
		text("selection: " ~ (sel.type == Json.Type.null_ || sel.type == Json.Type.undefined ? "none" : sel["points"].length.to!string ~ " points"));
	}
	with (t[2])
	{
		auto cities = new DataFrame()
			.addColumn("city", ["Almaty", "Astana", "Shymkent", "Karaganda"])
			.addColumn("lat", [43.2389, 51.1694, 42.3417, 49.8047])
			.addColumn("lon", [76.8897, 71.4491, 69.5901, 73.1094])
			.addColumn("radius_m", [40_000.0, 30_000, 28_000, 15_000]);
		map(cities, size: "radius_m", height: 360);
		caption("Circle radius in meters from the `radius_m` column. Tiles: OpenStreetMap (configurable via [map] tileUrl).");
	}
	auto comp = t[3];
	comp.components.html(`<div style="font-family:sans-serif;padding:8px;border:1px dashed #999">Static HTML in a sandboxed iframe</div>`, height: 60);
	auto v = counter(comp, jo2("label", "A D-declared component"), key: "c1", default_: Json(["count": Json(0)]));
	comp.write(format("Component value: count = **%s**", v["count"]));
}

Json jo2(string k, string v) { auto o = Json.emptyObject; o[k] = v; return o; }

mixin StreamlitMain!app;
