module apptests;

import std.algorithm;
import std.array;
import std.conv : to;
import streamlitd;

// ---------------------------------------------------------------- basic text + widgets

void helloApp(St st)
{
	st.title("Hello");
	auto name = st.textInput("Name", "World");
	auto n = st.slider("Count", 0, 10, 3);
	if (st.button("Greet"))
		st.success("Hi " ~ name ~ " x" ~ n.to!string);
	st.write("Name is", name, n);
}

unittest
{
	auto at = new AppTest(&helloApp).run();
	assert(at.lastStatus == RunStatus.ok);
	assert(at.headings == ["Hello"]);
	assert(at.alerts.length == 0);
	assert(at.markdowns == ["Name is World `3`"]);

	at.setValue("text_input", "Name", Json("Ann")).run();
	assert(at.markdowns == ["Name is Ann `3`"]);
	at.click("Greet").run();
	assert(at.alerts == ["Hi Ann x3"]);
	// button is true only for one run
	at.run();
	assert(at.alerts.length == 0);
	at.setValue("slider", "Count", Json(99)).run(); // clamped
	assert(at.widget("slider", "Count")["value"].get!long == 10);
}

// ---------------------------------------------------------------- session state, keys, callbacks

void counterApp(St st)
{
	st.session.setDefault("count", 0);
	st.button("Inc", onClick: () { st.session["count"] = st.session.get!int("count") + 1; });
	auto t = st.textInput("Keyed", key: "kt");
	if (st.button("Reset"))
	{
		st.session["kt"] = "reset!";
		st.rerun();
	}
	st.text("count=" ~ st.session.get!int("count").to!string ~ " kt=" ~ st.session.get!string("kt") ~ " t=" ~ t);
}

unittest
{
	auto at = new AppTest(&counterApp).run();
	assert(at.texts("text") == ["count=0 kt= t="]);
	at.click("Inc").run();
	at.click("Inc").run();
	assert(at.texts("text") == ["count=2 kt= t="]);
	at.setValueById("k:kt", Json("abc")).run();
	assert(at.texts("text") == ["count=2 kt=abc t=abc"]);
	at.click("Reset").run();
	assert(at.texts("text") == ["count=2 kt=reset! t=reset!"]);
	assert(at.widget("text_input", "Keyed")["value"].get!string == "reset!");
}

// ---------------------------------------------------------------- option widgets

void optionsApp(St st)
{
	auto c = st.selectbox("City", ["Almaty", "Astana", "Shymkent"], 1);
	auto r = st.radioOf("Size", [1, 2, 3]);
	auto m = st.multiselect("Tags", ["a", "b", "c"], ["b"]);
	auto rng = st.slider("Range", 0.0, 1.0, [0.2, 0.8]);
	auto ni = st.numberInput("Qty", 5, 0, 10);
	auto cb = st.checkbox("Agree");
	auto d = st.dateInput("Day", Date(2024, 1, 2));
	auto tm = st.timeInput("Time", TimeOfDay(9, 30));
	st.text([c, r.to!string, m.join("+"), rng.to!string, ni.to!string, cb.to!string, d.toISOExtString,
		tm.toString].join("|"));
}

unittest
{
	auto at = new AppTest(&optionsApp).run();
	assert(at.texts("text") == ["Astana|1|b|[0.2, 0.8]|5|false|2024-01-02|09:30:00"], at.texts("text")[0]);
	at.setValue("selectbox", "City", Json(2))
		.setValue("radio", "Size", Json(2))
		.setValue("multiselect", "Tags", Json([Json(0), Json(2)]))
		.setValue("slider", "Range", Json([Json(0.5), Json(0.1)]))
		.setValue("number_input", "Qty", Json(42))
		.setValue("checkbox", "Agree", Json(true))
		.setValue("date_input", "Day", Json("2025-05-06"))
		.setValue("time_input", "Time", Json("13:45"))
		.run();
	assert(at.texts("text") == ["Shymkent|3|a+c|[0.1, 0.5]|10|true|2025-05-06|13:45:00"], at.texts("text")[0]);
	// invalid value falls back to the default
	at.setValue("selectbox", "City", Json(17)).run();
	assert(at.texts("text")[0].startsWith("Astana|"));
}

// ---------------------------------------------------------------- duplicate ids, exceptions, stop

void dupApp(St st)
{
	st.button("Same");
	st.button("Same");
}

void errApp(St st)
{
	st.text("before");
	throw new Exception("boom");
}

void stopApp(St st)
{
	st.text("a");
	st.stop();
	st.text("b");
}

unittest
{
	auto at = new AppTest(&dupApp).run();
	assert(at.lastStatus == RunStatus.error);
	assert(at.exceptions.length == 1);
	assert(at.exceptions[0]["message"].get!string.canFind("multiple `button`"));

	at = new AppTest(&errApp).run();
	assert(at.lastStatus == RunStatus.error);
	assert(at.texts("text") == ["before"]);
	assert(at.exceptions[0]["message"].get!string == "boom");

	at = new AppTest(&stopApp).run();
	assert(at.lastStatus == RunStatus.stopped);
	assert(at.texts("text") == ["a"]);
}

// ---------------------------------------------------------------- layout & forms

void layoutApp(St st)
{
	st.sidebar.header("Side");
	auto cols = st.columns(2);
	cols[0].text("left");
	cols[1].text("right");
	auto tabs = st.tabs(["A", "B"]);
	tabs[1].text("in B");
	with (st.expander("More"))
		text("inside");
	auto ph = st.empty();
	ph.text("first");
	ph.text("second");
	auto f = st.form("f1", clearOnSubmit: true);
	auto name = f.textInput("Form name");
	if (f.formSubmitButton("Send"))
		st.success("sent " ~ name);
}

unittest
{
	auto at = new AppTest(&layoutApp).run();
	assert(at.texts("text") == ["left", "right", "in B", "inside", "second"], at.texts("text").to!string);
	auto blocks = at.elements("block").map!(e => e["block"].get!string).array;
	assert(blocks == ["horizontal", "column", "column", "tabs", "tab", "tab", "expander", "form"], blocks.to!string);
	// sidebar root is 1
	auto sideDelta = at.transport.deltas().filter!(d => d["path"][0].get!int == 1).array;
	assert(sideDelta.length == 1);

	auto id = at.widgetId("text_input", "Form name");
	at.submitForm("Send", [id: Json("Bob")]).run();
	assert(at.alerts == ["sent Bob"]);
	// cleared on submit
	assert(at.widget("text_input", "Form name")["value"].get!string == "");
	at.run();
	assert(at.alerts.length == 0);
}

// ---------------------------------------------------------------- data editor

void editorApp(St st)
{
	auto df = new DataFrame;
	df.addColumn("item", ["a", "b"]).addColumn("qty", [1, 2]);
	auto edited = st.dataEditor(df, numRows: "dynamic");
	st.text("total=" ~ edited.sum("qty").to!string ~ " rows=" ~ edited.length.to!string);
	st.lineChart(edited, x: "item");
	st.dataframe(edited);
}

unittest
{
	auto at = new AppTest(&editorApp).run();
	assert(at.texts("text") == ["total=3 rows=2"]);
	auto ed = at.elements("data_editor")[0];
	assert(ed["data"].length == 2, ed.toString);
	at.setValueById(ed["id"].get!string, parseJsonString(`{"edited":{"0":{"qty":10}},"added":[{"item":"c","qty":5}],"deleted":[1]}`)).run();
	assert(at.texts("text") == ["total=15 rows=2"], at.texts("text")[0]);
	assert(at.elements("vega_lite").length == 1);
	assert(at.elements("dataframe")[0]["data"].length == 2);
}

// ---------------------------------------------------------------- multipage

void page1(St st) { st.title("Page one"); }
void page2(St st) { st.title("Page two"); if (st.button("Go home")) st.switchPage("Page one"); }

void mpApp(St st)
{
	auto pg = st.navigation([Page(&page1, "Page one"), Page(&page2, "Page two", "📈")]);
	pg.run(st);
}

unittest
{
	auto at = new AppTest(&mpApp).run();
	assert(at.headings == ["Page one"]);
	auto nav = at.messages("navigation");
	assert(nav.length == 1 && nav[0]["pages"].length == 2);
	at.sess.pagePath = "page-two";
	at.run();
	assert(at.headings == ["Page two"]);
	at.click("Go home").run();
	assert(at.headings == ["Page one"]);
}

// ---------------------------------------------------------------- chat

void chatApp(St st)
{
	string[] msgs = st.session.get!(string[])("msgs");
	foreach (m; msgs)
		st.chatMessage("user").markdown(m);
	if (auto p = st.chatInput("Say"))
	{
		msgs ~= p;
		st.session["msgs"] = msgs;
		st.chatMessage("user").markdown(p);
		st.chatMessage("assistant").markdown("echo: " ~ p);
	}
}

unittest
{
	auto at = new AppTest(&chatApp).run();
	assert(at.markdowns.length == 0);
	assert(at.elements("chat_input").length == 1);
	at.chat("hi").run();
	assert(at.markdowns == ["hi", "echo: hi"], at.markdowns.to!string);
	at.chat("again").run();
	assert(at.markdowns == ["hi", "again", "echo: again"], at.markdowns.to!string);
}

// ---------------------------------------------------------------- interruption

unittest
{
	int runs;
	AppTest at;
	at = new AppTest((St st) {
		runs++;
		st.text("start");
		if (runs == 1)
			at.sess.requestRerun(); // simulate a client event arriving mid-run
		st.text("end");
	});
	at.run();
	assert(runs == 2);
	assert(at.texts("text") == ["start", "end"]);
}

// ---------------------------------------------------------------- server-side validation & chart width

void limitsApp(St st)
{
	auto t = st.textInput("Short", maxChars: 3);
	auto m = st.multiselect("Pick", ["a", "b", "c"], maxSelections: 2);
	auto d = st.dateInput("When", Date(2024, 6, 1), minValue: Date(2024, 1, 1), maxValue: Date(2024, 12, 31));
	st.text(t ~ "|" ~ m.join(",") ~ "|" ~ d.toISOExtString);
	auto df = new DataFrame().addColumn("v", [1, 2]);
	st.lineChart(df, useContainerWidth: false);
	st.barChart(df);
}

unittest
{
	auto at = new AppTest(&limitsApp).run();
	at.setValue("text_input", "Short", Json("abcdef"))
		.setValue("multiselect", "Pick", Json([Json(0), Json(1), Json(2)]))
		.setValue("date_input", "When", Json("2030-01-01"))
		.run();
	assert(at.texts("text") == ["abc|a,b|2024-12-31"], at.texts("text")[0]);
	auto charts = at.elements("vega_lite");
	assert(charts[0]["spec"]["width"].type == Json.Type.undefined);
	assert(charts[1]["spec"]["width"].get!string == "container");
}

// ---------------------------------------------------------------- themes

void themeApp(St st)
{
	st.setTheme("ocean", "dark");
	auto t = Theme("paper");
	t.overrides.primaryColor = "#123456";
	st.setTheme(t, allowThemeSwitch: false);
	if (st.button("bad"))
		st.setTheme("no-such-style");
}

unittest
{
	auto at = new AppTest(&themeApp).run();
	auto m = at.messages("set_theme");
	assert(m.length == 2);
	assert(m[0]["preset"].get!string == "ocean" && m[0]["mode"].get!string == "dark");
	assert(m[0]["allowSwitch"].get!bool);
	assert(m[1]["preset"].get!string == "paper" && !m[1]["allowSwitch"].get!bool);
	assert(m[1]["overrides"]["primaryColor"].get!string == "#123456");
	assert(at.sess.newSessionMessage()["themes"].length == themePresetNames().length);
	at.click("bad").run();
	assert(at.exceptions.length == 1 && at.exceptions[0]["message"].get!string.canFind("Unknown theme preset"));
}

// ---------------------------------------------------------------- fragments, dialog, status, new widgets

int fullRuns;
int fragRuns;

void fragApp(St st)
{
	fullRuns++;
	auto outer = st.slider("Outer", 0, 10, 1);
	st.text("outer=" ~ outer.to!string);
	st.fragment((St f) {
		fragRuns++;
		auto inner = f.slider("Inner", 0, 10, 2);
		f.text("inner=" ~ inner.to!string ~ " outerSeen=" ~ outer.to!string);
		if (f.button("Frag rerun"))
			f.rerun(scope_: "fragment");
		if (f.button("Full rerun"))
			f.rerun();
	});
	if (st.button("Open dialog"))
		st.dialog("Edit item", (St d) {
			auto name = d.textInput("Item name", "x");
			d.text("dialog name=" ~ name);
		});
	auto s = st.status("Working...");
	s.write("step 1");
	s.update(label: "Done", state: "complete");
	auto p = st.pills("Pick", ["a", "b", "c"]);
	auto pm = st.segmentedControlMulti("Many", ["x", "y", "z"], ["y"]);
	auto fb = st.feedback("stars");
	st.text("pills=" ~ (p is null ? "none" : p) ~ " seg=" ~ pm.join(",") ~ " fb=" ~ fb.to!string);
	st.linkButton("Docs", "https://dlang.org");
	st.badge("New", color: "green");
}

unittest
{
	fullRuns = fragRuns = 0;
	auto at = new AppTest(&fragApp).run();
	assert(fullRuns == 1 && fragRuns == 1);
	assert(at.texts("text") == ["outer=1", "inner=2 outerSeen=1", "pills=none seg=y fb=-1"], at.texts("text").to!string);
	auto inner = at.widget("slider", "Inner");
	assert(inner["fragment"].type == Json.Type.string);

	// a widget inside the fragment reruns only the fragment
	at.setValue("slider", "Inner", Json(7)).run();
	assert(fullRuns == 1 && fragRuns == 2, fullRuns.to!string ~ "/" ~ fragRuns.to!string);
	assert(at.texts("text") == ["outer=1", "inner=7 outerSeen=1", "pills=none seg=y fb=-1"], at.texts("text").to!string);

	// widgets outside rerun everything (and the fragment keeps its value)
	at.setValue("slider", "Outer", Json(5)).run();
	assert(fullRuns == 2 && fragRuns == 3);
	assert(at.texts("text")[1] == "inner=7 outerSeen=5");

	// st.rerun(scope: "fragment") vs full
	at.click("Frag rerun").run();
	assert(fullRuns == 2 && fragRuns == 5);
	at.click("Full rerun").run();
	assert(fullRuns == 3 && fragRuns == 7, fullRuns.to!string ~ "/" ~ fragRuns.to!string); // one fragment run, then one full run

	// dialog: opened by a button, its widgets rerun only the dialog
	at.click("Open dialog").run();
	assert(at.elements("block").map!(e => e["block"].get!string).canFind("dialog"));
	auto before = fullRuns;
	at.setValue("text_input", "Item name", Json("hammer")).run();
	assert(fullRuns == before);
	assert(at.texts("text").canFind("dialog name=hammer"));
	at.run(); // full rerun without the button: dialog closed
	assert(!at.elements("block").map!(e => e["block"].get!string).canFind("dialog"));

	// status container was updated in place
	auto st_ = at.elements("block").filter!(e => e["block"].get!string == "status").array;
	assert(st_.length == 1 && st_[0]["label"].get!string == "Done" && st_[0]["state"].get!string == "complete");
	assert(at.texts("markdown").canFind("step 1"));

	// new widgets
	at.setValue("pills", "Pick", Json(2)).setValue("segmented_control", "Many", Json([Json(0), Json(2)])).run();
	auto fbId = at.elements("feedback")[0]["id"].get!string;
	at.setValueById(fbId, Json(4)).run();
	assert(at.texts("text")[$ - 1] == "pills=c seg=x,z fb=4", at.texts("text")[$ - 1]);
	assert(at.elements("link_button").length == 1 && at.elements("badge").length == 1);
}

unittest
{
	// runEvery fragments are reported as due
	auto at = new AppTest((St st) {
		st.fragment((St f) { f.text("tick"); }, runEvery: 0.05);
	}).run();
	string due;
	import core.thread : Thread;
	import core.time : msecs;
	Thread.sleep(80.msecs);
	at.sess.nextFragmentDue(due);
	assert(due.length);
	at.sess.requestRerun(null, null, Json.undefined, due);
	auto runsBefore = at.runCount;
	at.run();
	assert(at.runCount == runsBefore + 1);
	assert(at.texts("text") == ["tick"]);
}
