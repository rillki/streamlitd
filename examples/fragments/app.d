/// Partial reruns (st.fragment), auto-refresh, dialogs, status and newer widgets.
import streamlitd;
import std.conv : to;
import std.format : format;
import std.datetime : Clock;

void app(St st)
{
	st.setPageConfig(title: "Fragments", icon: "🧩");
	st.title("Fragments & dialogs");
	st.session["fullRuns"] = st.session.get!int("fullRuns") + 1;
	st.text("full runs: " ~ st.session.get!int("fullRuns").to!string);
	auto factor = st.slider("Outer factor (reruns everything)", 1, 5, 1);

	st.subheader("st.fragment");
	st.fragment((St f) {
		st.session["fragRuns"] = st.session.get!int("fragRuns") + 1;
		auto n = f.slider("Inner value (reruns only this box)", 0, 100, 10);
		f.text(format("inner result: %d (fragment runs: %d)", n * factor, st.session.get!int("fragRuns")));
	});

	st.subheader("Auto-refresh (runEvery)");
	st.fragment((St f) {
		st.session["ticks"] = st.session.get!int("ticks") + 1;
		f.metric("Ticks", st.session.get!int("ticks"));
	}, runEvery: 0.5);

	st.subheader("st.dialog");
	if (st.button("Edit profile"))
		st.dialog("Edit profile", (St d) {
			auto name = d.textInput("Display name", st.session.get!string("name", "Ann"));
			d.text("preview: " ~ name);
			if (d.button("Save", type: "primary"))
			{
				st.session["name"] = name;
				st.rerun(); // closes the dialog
			}
		});
	st.write("Saved name:", st.session.get!string("name", "Ann"));

	st.subheader("st.status");
	if (st.button("Run job"))
	{
		auto s = st.status("Downloading data...", expanded: true);
		s.write("Fetched 3 files");
		st.sleep(0.2);
		s.write("Parsed rows");
		s.update(label: "Job complete", state: "complete", expanded: 0);
	}

	st.subheader("Newer widgets");
	auto size = st.pills("Size", ["S", "M", "L", "XL"]);
	auto days = st.segmentedControlMulti("Days", ["Mon", "Tue", "Wed", "Thu", "Fri"], ["Mon"]);
	auto view = st.segmentedControl("View", ["Table", "Chart"], 0);
	auto rating = st.feedback("stars");
	auto thumbs = st.feedback("thumbs");
	st.text(format("size=%s days=%s view=%s rating=%d thumbs=%d", size is null ? "-" : size, days, view, rating, thumbs));
	auto row = st.columns(2);
	row[0].linkButton("D language", "https://dlang.org", icon: "🔗");
	row[1].badge("Beta", icon: "✨", color: "violet");
}

mixin StreamlitMain!app;
