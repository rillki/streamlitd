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
	assert(m[0]["scheme"].get!string == "ocean" && m[0]["mode"].get!string == "dark");
	assert(m[0]["allowSwitch"].get!bool);
	assert(m[1]["scheme"].get!string == "paper" && !m[1]["allowSwitch"].get!bool);
	assert(m[1]["overrides"]["primaryColor"].get!string == "#123456");
	assert(at.sess.newSessionMessage()["themes"].length == colorSchemeNames().length);
	assert(at.sess.newSessionMessage()["designs"].length == designNames().length);
	at.click("bad").run();
	assert(at.exceptions.length == 1 && at.exceptions[0]["message"].get!string.canFind("Unknown color scheme"));
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

// ---------------------------------------------------------------- D Errors are reported, not fatal

unittest
{
	auto at = new AppTest((St st) {
		st.text("before");
		int[] a = [1, 2];
		size_t i = 5;
		st.text((a[i]).to!string); // RangeError
	}).run();
	assert(at.lastStatus == RunStatus.error);
	assert(at.texts("text") == ["before"]);
	assert(at.exceptions.length == 1);
	assert(at.exceptions[0]["type"].get!string.canFind("RangeError") || at.exceptions[0]["type"].get!string.canFind("ArrayIndexError"), at.exceptions[0].toString);
	assert(at.messages("script_finished").length == 1);
}

// ---------------------------------------------------------------- fragment media is released

unittest
{
	import streamlitd.media : MediaManager;
	int n;
	auto at = new AppTest((St st) {
		st.image(cast(const(ubyte)[]) "<svg>main</svg>", mime: "image/svg+xml");
		st.fragment((St f) {
			n++;
			f.image(cast(const(ubyte)[]) ("<svg>" ~ n.to!string ~ "</svg>"), mime: "image/svg+xml");
			f.button("again");
		});
	}).run();
	auto sid = at.sess.id;
	size_t owned()
	{
		size_t c;
		foreach (_, f; MediaManager.files)
			if (sid in f.owners)
				c++;
		return c;
	}
	assert(owned() == 2);
	foreach (i; 0 .. 5)
		at.click("again").run();
	assert(owned() == 2, owned().to!string); // old fragment images were released, main image kept
	assert(at.elements("image").length == 2);
}

unittest
{
	// st.login without [auth] is an API error (no redirect loop)
	auto at = new AppTest((St st) { st.login(); }).run();
	assert(at.exceptions.length == 1 && at.exceptions[0]["message"].get!string.canFind("needs authentication"));
	assert(at.messages("navigate").length == 0);
}

unittest
{
	auto at = new AppTest((St st) {
		auto n = st.pillsOf!int("N", [10, 20, 30], index: 1);
		auto m = st.segmentedControlOf!int("M", [1, 2], formatFunc: (int v) => "#" ~ v.to!string);
		st.text(n.to!string ~ "/" ~ m.to!string);
	}).run();
	assert(at.texts("text") == ["20/0"]);
	assert(at.widget("segmented_control", "M")["options"][0].get!string == "#1");
	at.setValue("segmented_control", "M", Json(1)).run();
	assert(at.texts("text") == ["20/2"]);
}

// ---------------------------------------------------------------- concurrent requests for different fragments

unittest
{
	int full, ticks, saves;
	auto at = new AppTest((St st) {
		full++;
		st.fragment((St f) { ticks++; f.text("tick"); }, runEvery: 1);
		st.fragment((St f) {
			if (f.button("Save"))
				saves++;
		});
	}).run();
	assert(full == 1);
	auto tickId = "f:0.0"; // fragment ids default to "f:" ~ path of the fragment block
	// a tick is queued, then the user clicks Save in the other fragment
	at.sess.requestRerun(null, null, Json.undefined, tickId);
	at.click("Save");
	at.run();
	assert(full == 1, "different fragments must not escalate to a full rerun");
	assert(saves == 1, "the click must reach its own fragment");
	assert(ticks == 2);
}

// ---------------------------------------------------------------- design styles

unittest
{
	auto at = new AppTest((St st) {
		st.setTheme(scheme: "ocean");
		st.setTheme(design: "terminal");          // keeps the scheme set above
		st.setTheme(mode: "dark");
		if (st.button("bad design"))
			st.setTheme(design: "no-such-design");
		if (st.button("page config"))
			st.setPageConfig(design: "win95", colorScheme: "paper");
	}).run();
	auto m = at.messages("set_theme");
	assert(m.length == 3);
	assert(m[1]["scheme"].get!string == "ocean" && m[1]["design"].get!string == "terminal");
	assert(m[2]["scheme"].get!string == "ocean" && m[2]["design"].get!string == "terminal" && m[2]["mode"].get!string == "dark");
	at.click("bad design").run();
	assert(at.exceptions.length == 1 && at.exceptions[0]["message"].get!string.canFind("Unknown design style"));
	at.run(); // the failing run stopped before drawing the next button
	at.click("page config").run();
	auto last = at.messages("set_theme")[$ - 1];
	assert(last["design"].get!string == "win95" && last["scheme"].get!string == "paper" && last["mode"].get!string == "dark");
}

unittest
{
	// int metric values with named arguments are not ambiguous
	auto at = new AppTest((St st) { st.metric("Users", 1830, "-2%", border: true); st.metric("Ratio", 0.5); }).run();
	assert(at.elements("metric")[0]["value"].get!string == "1830");
	assert(at.elements("metric")[1]["value"].get!string == "0.5");
}

unittest
{
	// a lock on the appearance menu holds for the rest of the run, and resets on the next run
	bool lockIt = true;
	auto at = new AppTest((St st) {
		if (lockIt)
			st.setPageConfig(allowThemeSwitch: false);
		st.setTheme(design: "terminal");
		st.setPageConfig(title: "t", colorScheme: "ocean");
	}).run();
	auto m = at.messages("set_theme");
	assert(m.length == 3);
	foreach (x; m)
		assert(!x["allowSwitch"].get!bool, x.toString);
	lockIt = false;
	at.run();
	foreach (x; at.messages("set_theme"))
		assert(x["allowSwitch"].get!bool, x.toString);
}

unittest
{
	// favicon: emoji/URL pass through, local files and bytes become app-served media
	import std.file : tempDir, write, remove;
	import std.path : buildPath;
	auto png = buildPath(tempDir, "streamlitd-fav-test.png");
	write(png, cast(const(ubyte)[]) [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]);
	scope (exit) remove(png);
	string which = "emoji";
	auto at = new AppTest((St st) {
		final switch (which)
		{
			case "emoji": st.setPageConfig(title: "t", icon: "📊"); break;
			case "url": st.setPageConfig(icon: "https://example.com/i.png"); break;
			case "file": st.setPageConfig(icon: png); break;
			case "bytes": st.setFavicon(cast(const(ubyte)[]) `<svg xmlns="http://www.w3.org/2000/svg"/>`, "image/svg+xml"); break;
		}
	}).run();
	assert(at.messages("page_config")[0]["icon"].get!string == "📊");
	which = "url";
	at.run();
	assert(at.messages("page_config")[0]["icon"].get!string == "https://example.com/i.png");
	which = "file";
	at.run();
	assert(at.messages("page_config")[0]["icon"].get!string.startsWith("_media/"));
	which = "bytes";
	at.run();
	assert(at.messages("page_config")[0]["icon"].get!string.startsWith("_media/"));
}

// ---------------------------------------------------------------- custom elements and widgets

struct Pick { string color; int n; }

unittest
{
	import std.exception : assertThrown;
	// the browser code is irrelevant here: AppTest talks to the session directly
	registerElement("t-stars", js: `StreamlitD.registerElement("t-stars", { render() {} });`);
	registerElement("t-badge", js: `StreamlitD.registerElement("t-badge", { render() {} });`, css: ".t-badge{}");
	int changes;
	bool useUnknown;
	auto at = new AppTest((St st) {
		st.customElement("t-badge", Json(["text": Json("beta")]));
		auto stars = st.customWidget!int("t-stars", "Stars", 3, Json(["max": Json(5)]), key: "stars",
			onChange: () { changes++; });
		auto pick = st.customWidget!Pick("t-stars", "Pick", Pick("red", 1));
		auto go = st.customWidget!string("t-stars", "Go", null, trigger: true);
		auto f = st.form("f");
		auto inForm = f.customWidget!int("t-stars", "In form", 0);
		f.formSubmitButton("Send");
		st.write("v", stars, pick.color, pick.n, go.length ? go : "-", inForm);
		if (useUnknown)
			st.customElement("t-nope");
	}).run();
	assert(at.markdowns == ["v `3` red `1` - `0`"], at.markdowns.to!string);
	auto badge = at.customElements("t-badge");
	assert(badge.length == 1 && badge[0]["props"]["text"].get!string == "beta" && badge[0]["id"].type == Json.Type.undefined);
	auto w = at.widget("custom", "Stars");
	assert(w["element"].get!string == "t-stars" && w["value"].get!int == 3 && w["props"]["max"].get!int == 5);
	assert(at.customElements("t-stars").length == 4);

	// a value from the browser, decoded into T; onChange and session state follow
	at.setValue("custom", "Stars", Json(5)).run();
	assert(at.markdowns[0].startsWith("v `5`") && changes == 1 && at.sess.session.get!int("stars") == 5);
	at.setValue("custom", "Pick", parseJsonString(`{"color":"blue","n":2}`)).run();
	assert(at.markdowns[0].canFind("blue `2`"), at.markdowns.to!string);
	// a value that does not decode falls back to the default
	at.setValue("custom", "Stars", Json("lots")).run();
	assert(at.markdowns[0].startsWith("v `3`"), at.markdowns.to!string);
	// trigger widgets return the value for the triggering run only
	at.sess.requestRerun(null, at.widgetId("custom", "Go"), Json("pressed"));
	at.run();
	assert(at.markdowns[0].canFind("pressed"), at.markdowns.to!string);
	at.click("Go", "custom").run(); // click() sends `true`, which is not a string: default
	assert(at.markdowns[0].canFind(" - "), at.markdowns.to!string);
	at.run();
	assert(at.markdowns[0].canFind(" - "), at.markdowns.to!string);
	// in a form: only on submit
	at.submitForm("Send", [at.widgetId("custom", "In form"): Json(7)]).run();
	assert(at.markdowns[0].endsWith("`7`"), at.markdowns.to!string);
	// unregistered names fail loudly
	useUnknown = true;
	at.run();
	assert(at.exceptions.length == 1 && at.exceptions[0]["message"].get!string.canFind("t-nope"));
	assertThrown(registerElement("t-stars", js: "x"));
}

// ---------------------------------------------------------------- app shell: navigation, header bar, footer, banner

unittest
{
	import std.exception : assertThrown;
	string picked;
	auto at = new AppTest((St st) {
		auto page = st.navigation([
			Page((St s) { s.text("home"); }, "Home"),
			Page((St s) { s.text("sales"); }, "Sales", section: "Reports"),
		], position: "top");
		st.banner("**Maintenance** at 18:00", "warning");
		st.banner("keyed", key: "k1", dismissible: false);
		st.topbar.button("Help");
		picked = st.userMenu(["Profile", "-", "Help"]);
		page.run(st);
		st.footer.caption("v1.0");
	}).run();
	auto nav = at.messages("navigation")[0];
	assert(nav["position"].get!string == "top" && nav["pages"][1]["section"].get!string == "Reports");
	assert(nav["pages"][0]["section"].type == Json.Type.undefined || nav["pages"][0]["section"].type == Json.Type.null_);
	// the new roots: 4 = header bar, 5 = footer, 6 = banners
	auto rootOf(string kind) { return at.transport.deltas().filter!(d => d["el"]["kind"].get!string == kind).map!(d => d["path"][0].get!int).array; }
	assert(rootOf("banner") == [6, 6] && rootOf("button") == [4] && rootOf("user_menu") == [4], rootOf("banner").to!string);
	auto caps = at.transport.deltas().filter!(d => d["el"]["kind"].get!string == "markdown" && d["path"][0].get!int == 5).array;
	assert(caps.length == 1);
	auto banners = at.elements("banner");
	assert(banners[0]["type"].get!string == "warning" && banners[0]["dismissible"].get!bool && banners[0]["key"].get!string.length);
	assert(banners[1]["key"].get!string == "k:k1" && !banners[1]["dismissible"].get!bool);

	// user menu: without [auth] it renders nothing (auth false); signed in: name, items, trigger value
	auto um = at.elements("user_menu")[0];
	assert(!um["auth"].get!bool && !um["loggedIn"].get!bool && um["items"].length == 3);
	at.sess.authEnabled = true;
	at.sess.user = parseJsonString(`{"sub":"ann","name":"Ann Lee","email":"ann@example.com","picture":"https://x/a.png"}`);
	at.run();
	um = at.elements("user_menu")[0];
	assert(um["loggedIn"].get!bool && um["name"].get!string == "Ann Lee" && um["picture"].get!string == "https://x/a.png" && um["logout"].get!bool);
	at.sess.requestRerun(null, um["id"].get!string, Json("Profile"));
	at.run();
	assert(picked == "Profile");
	at.run();
	assert(picked is null);                                   // a trigger: only for that run
	at.sess.requestRerun(null, um["id"].get!string, Json("Not an item"));
	at.run();
	assert(picked is null);                                   // unknown items are ignored

	auto bad = new AppTest((St st) { st.banner("x", "purple"); }).run();
	assert(bad.exceptions.length == 1);
	bad = new AppTest((St st) { st.navigation([Page((St s) {}, "A")], position: "left"); }).run();
	assert(bad.exceptions.length == 1 && bad.exceptions[0]["message"].get!string.canFind("position"));
}

// ---------------------------------------------------------------- menus and navigation: menuButton, breadcrumbs, pagination

unittest
{
	string action;
	size_t page;
	size_t total = 95;
	auto at = new AppTest((St st) {
		auto p = st.navigation([
			Page((St s) { s.breadcrumbs(); }, "Home"),
			Page((St s) { s.breadcrumbs(); }, "Sales", section: "Reports"),
		]);
		p.run(st);
		st.breadcrumbs(["Customers", "ACME", "Invoices"], ["customers", null]);
		action = st.menuButton("Export", ["CSV", "-", "Print"]);
		page = st.pagination(total, 10);
	}).run();
	// breadcrumbs from navigation: just the page on the default page
	auto bc = at.elements("breadcrumbs");
	assert(bc[0]["items"].length == 1 && bc[0]["items"][0]["label"].get!string == "Home");
	assert(bc[1]["items"][0]["urlPath"].get!string == "customers" && bc[1]["items"][1]["urlPath"].type != Json.Type.string);
	at.sess.pagePath = "sales";
	at.run();
	bc = at.elements("breadcrumbs");
	assert(bc[0]["items"].length == 3 && bc[0]["items"][1]["label"].get!string == "Reports" && bc[0]["items"][1]["urlPath"].type != Json.Type.string);
	assert(bc[0]["items"][0]["urlPath"].get!string == "" && bc[0]["items"][2]["urlPath"].get!string == "sales");

	// menu button: a trigger with validated items
	auto mb = at.widget("menu_button", "Export");
	assert(mb["items"].length == 3 && action is null);
	at.sess.requestRerun(null, mb["id"].get!string, Json("Print"));
	at.run();
	assert(action == "Print");
	at.run();
	assert(action is null);
	at.sess.requestRerun(null, mb["id"].get!string, Json("-"));
	at.run();
	assert(action is null);                                  // the separator is not an item

	// pagination: 1-based, clamped, kept when the total changes
	auto pg = at.widget("pagination", "Pages");
	assert(pg["pages"].get!int == 10 && page == 1);
	at.setValue("pagination", "Pages", Json(7)).run();
	assert(page == 7);
	at.setValue("pagination", "Pages", Json(99)).run();
	assert(page == 10);
	total = 25;                                              // fewer items: back inside the range
	at.run();
	assert(page == 3 && at.widget("pagination", "Pages")["value"].get!int == 3);
	total = 0;
	at.run();
	assert(page == 1 && at.widget("pagination", "Pages")["pages"].get!int == 1);

	auto bad = new AppTest((St st) { st.breadcrumbs(); }).run();
	assert(bad.exceptions.length == 1 && bad.exceptions[0]["message"].get!string.canFind("navigation"));
}

// ---------------------------------------------------------------- content and inputs: card, stepper, skeleton, timeline,
// avatar, details, tags, tree select, date range, copy button

unittest
{
	string[] tags, regions;
	DateRange period;
	auto at = new AppTest((St st) {
		auto c = st.card("Revenue", "Last 30 days", icon: "💰");
		c.metric("Revenue", "$1k");
		st.stepper(["A", "B", "C"], 1);
		st.stepper(["A"], 9, "vertical");
		st.skeleton(0);
		st.timeline([TimelineItem("Shipped", "11:05", "via **DHL**", "🚚", "info")]);
		st.avatar("Ann Lee", size: "large");
		st.details([["Customer", "ACME"], ["Since", "2019"]]);
		st.details(parseJsonString(`{"plan":"pro","seats":5}`));
		tags = st.tagsInput("Tags", [" a ", "b", "a", ""], ["x"], maxTags: 3);
		regions = st.treeSelect("Regions", [TreeNode("eu", "Europe", [TreeNode("de", "Germany"), TreeNode("fr", "France")]),
			TreeNode("us", "USA")], ["de", "nope"]);
		period = st.dateRangeInput("Period", DateRange(Date(2026, 1, 31), Date(2026, 1, 1)), maxValue: Date(2026, 1, 20));
		st.copyButton("secret-link", "Copy link");
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto card = at.elements("block").filter!(b => b["block"].get!string == "card").array;
	assert(card.length == 1 && card[0]["title"].get!string == "Revenue" && card[0]["icon"].get!string == "💰");
	assert(at.elements("metric").length == 1);
	auto steps = at.elements("stepper");
	assert(steps[0]["current"].get!int == 1 && steps[1]["current"].get!int == 1 && steps[1]["orientation"].get!string == "vertical");
	assert(at.elements("skeleton")[0]["lines"].get!int == 1);
	auto tl = at.elements("timeline")[0]["items"][0];
	assert(tl["title"].get!string == "Shipped" && tl["type"].get!string == "info" && tl["icon"].get!string == "🚚");
	assert(at.elements("avatar")[0]["size"].get!string == "large");
	auto det = at.elements("details");
	assert(det[0]["rows"].length == 2 && det[0]["rows"][0][0].get!string == "Customer" && det[0]["rows"][0][1].get!string == "ACME");
	assert(det[1]["rows"].length == 2 && det[1]["rows"][1][1].get!string == "5");
	assert(at.elements("copy_button")[0]["text"].get!string == "secret-link");

	// tags: trimmed, de-duplicated, limited
	assert(tags == ["a", "b"], tags.to!string);
	at.setValue("tags_input", "Tags", parseJsonString(`["x", " y", "x", "z", "w"]`)).run();
	assert(tags == ["x", "y", "z"], tags.to!string);
	// tree: unknown ids dropped; nodes in JSON; single mode keeps one
	assert(regions == ["de"]);
	assert(at.widget("tree_select", "Regions")["nodes"][0]["children"].length == 2);
	at.setValue("tree_select", "Regions", parseJsonString(`["eu", "de", "fr", "zz", "us"]`)).run();
	assert(regions == ["eu", "de", "fr", "us"], regions.to!string);
	// date range: ordered and clamped
	assert(period == DateRange(Date(2026, 1, 1), Date(2026, 1, 20)), period.to!string);
	at.setValue("date_range_input", "Period", parseJsonString(`["2026-01-15", "2026-01-03"]`)).run();
	assert(period == DateRange(Date(2026, 1, 3), Date(2026, 1, 15)));
	at.setValue("date_range_input", "Period", Json("2026-01-05")).run(); // not a pair: default
	assert(period == DateRange(Date(2026, 1, 1), Date(2026, 1, 20)));

	auto single = new AppTest((St st) {
		st.write(st.treeSelect("One", [TreeNode("a", "A"), TreeNode("b", "B")], ["a", "b"], multi: false).join(","));
	}).run();
	assert(single.markdowns == ["a"]);
	auto dup = new AppTest((St st) { st.treeSelect("Dup", [TreeNode("a", "A"), TreeNode("a", "B")]); }).run();
	assert(dup.exceptions.length == 1 && dup.exceptions[0]["message"].get!string.canFind("duplicate"));
	auto bad = new AppTest((St st) { st.timeline([TimelineItem("x", null, null, null, "purple")]); }).run();
	assert(bad.exceptions.length == 1);
	auto badDetails = new AppTest((St st) { st.details(Json(5)); }).run();
	assert(badDetails.exceptions.length == 1 && badDetails.exceptions[0]["message"].get!string.canFind("JSON object"));
}

// tree select: the server keeps the value the way the browser does (subtrees, complete parents, tree order)
unittest
{
	auto tree = [TreeNode("eu", "Europe", [TreeNode("de", "Germany"), TreeNode("fr", "France")]),
		TreeNode("us", "USA"), TreeNode("as", "Asia", [TreeNode("jp", "Japan", [TreeNode("tk", "Tokyo")])])];
	string[] v;
	auto at = new AppTest((St st) { v = st.treeSelect("Regions", tree, ["eu"]); }).run();
	assert(v == ["eu", "de", "fr"], v.to!string);                       // a parent id = its subtree
	assert(at.widget("tree_select", "Regions")["value"].length == 3);  // the browser gets the same
	at.setValue("tree_select", "Regions", parseJsonString(`["fr", "us", "de"]`)).run();
	assert(v == ["eu", "de", "fr", "us"], v.to!string);                 // complete parent added, tree order
	at.setValue("tree_select", "Regions", parseJsonString(`["tk"]`)).run();
	assert(v == ["as", "jp", "tk"], v.to!string);                       // completes up to the root
	at.setValue("tree_select", "Regions", parseJsonString(`["eu", "fr"]`)).run();
	assert(v == ["eu", "de", "fr"], v.to!string);
	string[] one;
	new AppTest((St st) { one = st.treeSelect("One", tree, ["zz", "jp", "us"], multi: false); }).run();
	assert(one == ["jp"]);
}

// values set through st.session[key] are normalized like browser values
unittest
{
	string[] tags, regions;
	DateRange period;
	auto at = new AppTest((St st) {
		if (st.button("set"))
		{
			st.session["tags"] = [" a", "a", "b", "c", "d"];
			st.session["regions"] = ["zz", "de"];
			st.session["period"] = DateRange(Date(2026, 3, 1), Date(2025, 1, 1));
		}
		tags = st.tagsInput("Tags", null, maxTags: 3, key: "tags");
		regions = st.treeSelect("Regions", [TreeNode("eu", "Europe", [TreeNode("de", "Germany")])], key: "regions");
		period = st.dateRangeInput("Period", DateRange(Date(2026, 1, 1), Date(2026, 1, 2)),
			minValue: Date(2026, 1, 1), maxValue: Date(2026, 1, 31), key: "period");
	}).run();
	at.click("set").run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	assert(tags == ["a", "b", "c"], tags.to!string);
	assert(regions == ["eu", "de"], regions.to!string);
	assert(period == DateRange(Date(2026, 1, 1), Date(2026, 1, 31)), period.to!string);
	assert(at.widget("date_range_input", "Period")["value"][1].get!string == "2026-01-31");
}

// userMenu without [auth]: emitted (so the browser can hide it), marked as not available
unittest
{
	auto at = new AppTest((St st) { st.userMenu(["Profile"]); }).run();
	assert(at.exceptions.length == 0);
	auto um = at.widget("user_menu", null);
	assert(!um["auth"].get!bool && !um["loggedIn"].get!bool);
}
