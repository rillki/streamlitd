/// Design styles: pick a preset from code (st.setTheme) or from the ⚙ menu.
import streamlitd;
import std.math : sin, cos;
import std.algorithm : map;
import std.array : array;
import std.range : iota;

void app(St st)
{
	auto presets = themePresetNames();
	with (st.sidebar)
	{
		header("Design style");
		auto style = selectbox("App style (st.setTheme)", presets, key: "style");
		auto mode = radio("Mode", ["auto", "light", "dark"], horizontal: true, key: "mode");
		auto lock = checkbox("Lock style for viewers", key: "lock");
		auto custom = checkbox("Custom primary color", key: "custom");
		Theme t = Theme(style, mode);
		if (custom)
			t.overrides.primaryColor = colorPicker("Primary color", "#7c3aed", key: "primary");
		setPageConfig(title: "Design styles", icon: "🎨", layout: Layout.wide);
		setTheme(t, allowThemeSwitch: !lock);
		caption("Viewers can also switch style and mode from the ⚙ menu (top right) unless locked.");
	}

	st.title("Design styles 🎨");
	st.markdown("Every preset has a light and a dark variant. Code, `inline code`, [links](https://dlang.org) and :primary[accent text].");

	auto c = st.columns(3);
	c[0].metric("Revenue", "$12.4k", "+8%");
	c[1].metric("Users", 1830, "-2%");
	c[2].metric("Latency", "120 ms", "-14 ms", deltaColor: "inverse");

	auto l = st.columns(2);
	with (l[0])
	{
		textInput("Text input", "Hello");
		selectbox("Selectbox", ["Alpha", "Beta", "Gamma"]);
		multiselect("Multiselect", ["D", "Python", "Rust"], ["D", "Rust"]);
		slider("Slider", 0, 100, 40);
		auto b = columns(2);
		b[0].button("Primary", type: "primary");
		b[1].button("Secondary");
	}
	with (l[1])
	{
		checkbox("Checkbox", true);
		toggle("Toggle", true);
		radio("Radio", ["One", "Two", "Three"], horizontal: true);
		numberInput("Number", 42);
		info("An informational message.");
		success("A success message.");
	}

	auto x = iota(50).map!(i => i * 0.25).array;
	auto df = new DataFrame()
		.addColumn("x", x)
		.addColumn("a", x.map!(v => sin(v)).array)
		.addColumn("b", x.map!(v => cos(v)).array)
		.addColumn("c", x.map!(v => sin(v) * cos(v)).array);
	auto g = st.columns(2);
	g[0].lineChart(df, x: "x", height: 260);
	g[1].barChart(new DataFrame().addColumn("team", ["A", "B", "C", "D", "E"]).addColumn("score", [12, 19, 7, 15, 10]),
		x: "team", height: 260);

	auto t = st.tabs(["Table", "Code"]);
	t[0].dataframe(df.head(6), hideIndex: true);
	t[1].code("void app(St st)\n{\n    st.setTheme(\"ocean\", \"dark\");\n}\n", "d");
	with (st.expander("Chat bubbles"))
	{
		chatMessage("user").write("Which style do you like?");
		chatMessage("assistant").write("All of them, in light **and** dark.");
	}
}

mixin StreamlitMain!app;
