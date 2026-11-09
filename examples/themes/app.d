/// Design gallery: design styles × color schemes × light/dark.
/// Pick them from code (st.setTheme) in the sidebar, or from the ⚙ menu (top right).
import streamlitd;
import std.math : sin, cos;
import std.algorithm : map;
import std.array : array;
import std.range : iota;

void app(St st)
{
	with (st.sidebar)
	{
		header("Appearance");
		auto design = selectbox("Design style", designNames(), key: "design");
		auto scheme = selectbox("Color scheme", colorSchemeNames(), key: "scheme");
		auto mode = radio("Mode", ["auto", "light", "dark"], horizontal: true, key: "mode");
		auto lock = checkbox("Lock appearance for viewers", key: "lock");
		auto custom = checkbox("Custom primary color", key: "custom");
		Theme t = Theme(scheme, mode, design);
		if (custom)
			t.overrides.primaryColor = colorPicker("Primary color", "#7c3aed", key: "primary");
		setPageConfig(title: "Design gallery", icon: "🎨", layout: Layout.wide);
		setTheme(t, allowThemeSwitch: !lock);
		caption("Viewers can also switch design, color scheme and mode from the ⚙ menu (top right) unless locked.");
	}

	st.title("Design gallery 🎨");
	st.markdown("Every **design style** works with every **color scheme**, in light and dark mode. " ~
		"Code, `inline code`, [links](https://dlang.org) and :primary[accent text].");

	auto c = st.columns(3);
	c[0].metric("Revenue", "$12.4k", "+8%", border: true);
	c[1].metric("Users", 1830, "-2%", border: true);
	c[2].metric("Latency", "120 ms", "-14 ms", deltaColor: "inverse", border: true);

	auto l = st.columns(2);
	with (l[0])
	{
		textInput("Text input", "Hello");
		selectbox("Selectbox", ["Alpha", "Beta", "Gamma"]);
		multiselect("Multiselect", ["D", "Python", "Rust", "Go"], ["D", "Rust"], maxSelections: 3);
		auto opt = selectbox("Optional choice", ["Red", "Green", "Blue"], index: -1, placeholder: "Pick a color");
		text("optional: " ~ (opt is null ? "none" : opt));
		slider("Slider", 0, 100, 40);
		auto b = columns(3);
		b[0].button("Primary", type: "primary");
		b[1].button("Secondary");
		if (b[2].button("Open dialog"))
			st.dialog("A dialog", (St d) {
				d.write("Dialogs follow the design too.");
				d.textInput("Your name", "Ann");
				d.button("OK", type: "primary");
			});
	}
	with (l[1])
	{
		checkbox("Checkbox", true);
		toggle("Toggle", true);
		radio("Radio", ["One", "Two", "Three"], horizontal: true);
		numberInput("Number", 42);
		pills("Pills", ["Day", "Week", "Month"], 1);
		progress(65, "Progress");
	}
	auto pk = st.columns(3);
	auto day = pk[0].dateInput("Date", Date(2024, 5, 17), minValue: Date(2024, 5, 3), maxValue: Date(2024, 6, 20));
	pk[0].caption("date: " ~ day.toISOExtString);
	auto tm = pk[1].timeInput("Time", TimeOfDay(9, 30));
	pk[1].caption("time: " ~ tm.toISOExtString[0 .. 5]);
	auto col = pk[2].colorPicker("Color", "#ff4b4b");
	pk[2].caption("color: " ~ col);

	st.info("An informational message.");
	st.success("A success message.");

	auto x = iota(50).map!(i => i * 0.25).array;
	auto df = new DataFrame()
		.addColumn("x", x)
		.addColumn("a", x.map!(v => sin(v)).array)
		.addColumn("b", x.map!(v => cos(v)).array);
	auto g = st.columns(2);
	g[0].lineChart(df, x: "x", height: 240);
	g[1].barChart(new DataFrame().addColumn("team", ["A", "B", "C", "D", "E"]).addColumn("score", [12, 19, 7, 15, 10]),
		x: "team", height: 240);

	auto t = st.tabs(["Table", "Form", "Code"]);
	t[0].dataframe(df.head(5), hideIndex: true);
	with (t[1])
	{
		auto f = form("gallery_form");
		f.textInput("Email", "ann@example.com");
		f.selectbox("Plan", ["Free", "Pro"]);
		f.formSubmitButton("Submit", type: "primary");
	}
	t[2].code("void app(St st)\n{\n    st.setTheme(design: \"terminal\", scheme: \"solarized\", mode: \"dark\");\n}\n", "d");

	with (st.expander("An expander", expanded: true))
	{
		write("Expanders, forms, dialogs and status boxes get the design's container chrome.");
		chatMessage("user").write("Which design do you like?");
		chatMessage("assistant").write("All of them, in light **and** dark.");
	}
}

mixin StreamlitMain!app;
