/// Partial reruns (st.fragment), auto-refresh, dialogs, status and newer widgets.
import streamlitd;
import std.conv : to;
import std.format : format;
import std.datetime : Clock;
import core.atomic : atomicLoad, atomicOp;

/// Events from outside the app (a file watcher, a queue, an API route...); shared by all tabs.
shared int g_events;

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

	st.subheader("Pushed by events (refreshOn / refreshFragments)");
	// rerun as soon as something outside the app calls refreshFragments("events"), in every tab
	st.fragment((St f) {
		f.metric("Events received", atomicLoad(g_events));
	}, refreshOn: "events");
	if (st.button("Simulate an event"))
	{
		import core.thread : Thread;
		import core.time : msecs;
		// another thread, as a watcher or queue consumer would be
		new Thread({
			Thread.sleep(300.msecs);
			atomicOp!"+="(g_events, 1);
			refreshFragments("events");
		}).start();
	}
	// polling, but only running when something changed: refreshWhen is asked every second
	auto shown = new int;
	*shown = -1;
	st.fragment((St f) {
		*shown = atomicLoad(g_events);
		st.session["pollRuns"] = st.session.get!int("pollRuns") + 1;
		f.text(format("polled view: %d events (ran %d times)", *shown, st.session.get!int("pollRuns")));
	}, runEvery: 1, refreshWhen: () => atomicLoad(g_events) != *shown);

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
