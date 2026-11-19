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

// ---------------------------------------------------------------- accounts: st.user roles, requireRole, userAdmin

unittest
{
	// roles on st.user; requireRole stops the run with an error
	string[] seen;
	auto at = new AppTest((St st) {
		seen = st.user.roles;
		st.requireRole("editor");
		st.write("secret");
	});
	at.loginAs("ann", ["editor"]).run();
	assert(seen == ["editor"] && at.markdowns.canFind("secret"));
	at.loginAs("bob", ["viewer"]).run();
	assert(!at.markdowns.canFind("secret") && at.alerts.length == 1);
	auto u = new AppTest((St st) { st.write(st.user.isAdmin, st.user.hasRole("x"), st.user.username); });
	u.loginAs("root", ["admin"]).run();
	assert(u.markdowns == ["`true` `false` root"], u.markdowns.to!string);
}

unittest
{
	// the admin panel works on the account service: add a user, roles, disable, reset link, invites
	import std.string : indexOf;
	auto secret = cast(immutable(ubyte)[]) "0123456789abcdef!";
	AccountSettings s;
	s.registration = Registration.invite;
	auto acc = new Accounts(s, new MemoryUserStore, Json.emptyObject, secret, "/app");
	AppTest.useAccounts(acc);
	scope (exit) AppTest.useAccounts(null);
	acc.createUser("root", "blue horse 7", "Root", null, ["admin"]);

	auto at = new AppTest((St st) { st.userAdmin(); });
	at.loginAs("bob", ["viewer"]).run(); // not in the store, no admin role
	assert(at.alerts.length == 1 && at.elements("dataframe").length == 0);

	at.loginAs("root").run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	assert(at.elements("dataframe").length == 1);
	// add a user through the form (the password is hashed by the service)
	at.submitForm("Create user", [
		at.widgetId("text_input", "Username"): Json("Carol"),
		at.widgetId("text_input", "Password"): Json("green tree 42"),
		at.widgetId("tags_input", "Roles"): parseJsonString(`["editor"]`),
	]).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto carol = acc.user("carol");
	assert(carol !is null && carol.roles == ["editor"] && carol.passwordHash.startsWith("pbkdf2_sha256$"));
	// manage carol: roles, disable, reset link
	at.setValue("selectbox", "Manage user", Json(1)).run(); // ["root", "carol"]
	at.setValue("tags_input", "Roles", parseJsonString(`["editor", "viewer"]`)).run();
	at.click("Save roles").run();
	assert(acc.user("carol").roles == ["editor", "viewer"]);
	at.click("Disable").run();
	assert(acc.user("carol").disabled);
	at.click("Create a password reset link").run();
	auto link = at.elements("code")[0]["body"].get!string;
	assert(link.startsWith("/app/auth/reset?token=") && acc.resetTokenUser(link[link.indexOf("token=") + 6 .. $]) is null); // disabled
	at.click("Enable").run();
	assert(!acc.user("carol").disabled && acc.resetTokenUser(link[link.indexOf("token=") + 6 .. $]) == "carol");
	// the admin cannot disable or delete themselves
	at.setValue("selectbox", "Manage user", Json(0)).run();
	assert(at.widget("button", "Disable")["disabled"].get!bool && at.widget("button", "Delete user")["disabled"].get!bool);
	// invites: a one-time link (the validity field has its own key and no stray help text)
	auto days = at.widget("number_input", "Valid for (days)");
	assert(days["id"].get!string.canFind("inv-days") && days["help"].type == Json.Type.null_, days.toString);
	at.click("Create invite").run();
	assert(acc.invites.length == 1);
	auto inv = at.elements("code")[0]["body"].get!string;
	assert(inv.startsWith("/app/auth/register?invite="));
	auto u = acc.register("dave", "orange cat 3", null, null, inv[inv.indexOf("invite=") + 7 .. $]);
	assert(u.username == "dave" && acc.invites.length == 0);
}

// ---------------------------------------------------------------- header controls: rerun / appearance buttons

unittest
{
	auto at = new AppTest((St st) {
		st.setPageConfig(rerunButton: "menu", settingsButton: "hidden");
		st.sidebar.rerunButton();
		st.footer.settingsButton("Theme", "🎨");
		st.userMenu(["Help"], rerun: true, appearance: true);
	});
	at.loginAs("ann").run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto pc = at.messages("page_config")[0];
	assert(pc["rerunButton"].get!string == "menu" && pc["settingsButton"].get!string == "hidden");
	assert(at.elements("rerun_button")[0]["label"].get!string == "Rerun");
	auto sb = at.elements("settings_button")[0];
	assert(sb["label"].get!string == "Theme" && sb["icon"].get!string == "🎨");
	auto um = at.widget("user_menu", null);
	assert(um["rerun"].get!bool && um["appearance"].get!bool);
	auto bad = new AppTest((St st) { st.setPageConfig(rerunButton: "footer"); }).run();
	assert(bad.exceptions.length == 1);
}

// ---------------------------------------------------------------- event-driven fragment refresh (issue #1)

unittest
{
	// FragmentRef.refresh(): reruns only that fragment; a no-op once the fragment is gone
	int full, frag;
	bool draw = true;
	FragmentRef live;
	auto at = new AppTest((St st) {
		full++;
		if (draw)
			live = st.fragment((St f) { frag++; f.write("tick", frag); }, key: "live");
	});
	at.run();
	assert(full == 1 && frag == 1 && live.alive && live.id == "fk:live");
	assert(live.refresh());
	at.run();
	assert(full == 1 && frag == 2, [full, frag].to!string); // the fragment only
	draw = false;
	at.run();                                                // a full run that no longer draws it
	assert(full == 2 && !live.alive && !live.refresh());
	assert(FragmentRef.init.refresh() == false);
}

unittest
{
	// refreshFragments(topic): every open session's subscribed fragments, from any thread
	import core.thread : Thread;
	int a, b, other;
	auto app1 = new AppTest((St st) {
		st.fragment((St f) { a++; }, refreshOn: "orders, stock");
		st.fragment((St f) { other++; }, refreshOn: "news");
	});
	auto app2 = new AppTest((St st) { st.fragment((St f) { b++; }, refreshOn: "orders"); });
	app1.run();
	app2.run();
	assert(a == 1 && b == 1 && other == 1);
	size_t queued;
	auto t = new Thread({ queued = refreshFragments("orders"); });
	t.start();
	t.join();
	assert(queued == 2);
	app1.run();
	app2.run();
	assert(a == 2 && b == 2 && other == 1, [a, b, other].to!string);
	assert(refreshFragments("stock") == 1 && refreshFragments("nobody") == 0);
	app1.run();
	assert(a == 3);
	app1.sess.close();
	assert(refreshFragments("stock") == 0); // closed sessions are not asked
}

unittest
{
	// a push that arrives while the fragment is running does not interrupt it: it finishes, then
	// runs once more (frequent pushes must not starve a fragment)
	int started, finished;
	auto at = new AppTest((St st) {
		st.fragment((St f) {
			started++;
			if (started == 2)
				refreshFragments("busy"); // an event during this fragment run
			f.write("run", started);       // the next st.* call: interrupted without the fix
			finished++;
		}, refreshOn: "busy");
	});
	at.run();
	assert(started == 1 && finished == 1);
	assert(refreshFragments("busy") == 1);
	at.run();
	assert(started == 3 && finished == 3, [started, finished].to!string); // run 2 finished, then exactly one more
}

// ---------------------------------------------------------------- tables: column config, totals, cell styles, editor rules

unittest
{
	alias C = ColumnConfig;
	auto df = new DataFrame()
		.addColumn("name", ["a", "b"])
		.addColumn("amount", [5, -3])
		.addColumn("guid", ["g1", "g2"]);
	auto at = new AppTest((St st) {
		st.dataframe(df, columnConfig: [
			"amount": C.number("Amount", format: "%+d", color: "sign", group: "Money"),
			"guid": C.hide(),
		], totals: ["name": "Total", "amount": "sum"],
			cellStyle: (size_t r, string c, Json v) => c == "amount" && v.get!long < 0 ? "bg:error bold" : null);
		st.table(df, columnConfig: ["name": C.text("Name")]);
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto d = at.elements("dataframe")[0];
	assert(d["config"]["amount"]["format"].get!string == "%+d" && d["config"]["amount"]["group"].get!string == "Money");
	assert(d["config"]["guid"]["hidden"].get!bool);
	assert(d["totals"]["name"].get!string == "Total" && d["totals"]["amount"].get!string == "sum");
	assert(d["styles"]["1,1"].get!string == "bg:error bold" && d["styles"].length == 1);
	assert(at.elements("table")[0]["config"]["name"]["label"].get!string == "Name");
	// a typo in a column name is an error, not silently ignored
	auto bad = new AppTest((St st) { st.dataframe(df, columnConfig: ["amout": C.number()]); }).run();
	assert(bad.exceptions.length == 1 && bad.exceptions[0]["message"].get!string.canFind("amout"));
}

unittest
{
	// the editor keeps values its column config does not allow (the browser should not send them)
	alias C = ColumnConfig;
	auto df = new DataFrame()
		.addColumn("task", ["a", "b"])
		.addColumn("hours", [1, 2])
		.addColumn("prio", ["low", "high"])
		.addColumn("note", ["x", "y"]);
	DataFrame result;
	auto at = new AppTest((St st) {
		result = st.dataEditor(df, key: "ed", numRows: "dynamic", columnConfig: [
			"hours": C.number(min: 0, max: 24),
			"prio": C.select(options: ["low", "high"], required: true),
			"note": C.text(disabled: true),
			"task": C.text(maxChars: 3),
		]);
	}).run();
	auto id = at.widgetId("data_editor", null);
	at.setValueById(id, parseJsonString(`{"edited": {"0": {"hours": 30, "prio": "urgent", "note": "z", "task": "toolong"},
		"1": {"hours": 5, "prio": "low", "task": "ok"}}, "added": [{"task": "new", "hours": -1, "prio": "nope"}]}`)).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	assert(result.column!long("hours")[0 .. 2] == [1, 5], result.column!long("hours").to!string);
	assert(result.column!string("prio")[0 .. 2] == ["low", "low"]);
	assert(result.column!string("note")[0] == "x" && result.column!string("task")[0 .. 2] == ["a", "ok"]);
	// an added row may be incomplete, but invalid values are dropped
	assert(result.length == 3 && result.cell(2, 1).type == Json.Type.null_ && result.cell(2, 2).type == Json.Type.null_);
}

// ---------------------------------------------------------------- tables: selection and tree rows

unittest
{
	auto df = new DataFrame()
		.addColumn("mgr", ["Ann", "Ann", "Bob"])
		.addColumn("name", ["x", "y", "z"])
		.addColumn("id", ["i1", "i2", "i3"]);
	TableSelection sel, multiSel, cell;
	auto at = new AppTest((St st) {
		sel = st.dataframe(df, onSelect: "rerun", rowKey: "id", key: "one", groupBy: ["mgr"], totals: ["name": "count"]);
		multiSel = st.dataframe(df, onSelect: "rerun", selectionMode: "multi-row", key: "many");
		cell = st.dataframe(df, onSelect: "rerun", selectionMode: "single-cell", key: "cell");
		st.dataframe(df); // not a widget
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	assert(sel.empty && multiSel.empty);
	auto e = at.elements("dataframe");
	assert(e[0]["groupBy"][0].get!string == "mgr" && e[0]["selectionMode"].get!string == "single-row" && e[0]["id"].get!string == "k:one");
	assert(e[3]["id"].type == Json.Type.undefined);
	// a row by index: the key comes along; single-row keeps one
	at.selectRows("one", 2, 0).run();
	assert(sel.rows == [2] && sel.keys == [Json("i3")], sel.rows.to!string);
	// with rowKey, keys win over indices (stable when the frame is filtered or reordered)
	at.setValueById("k:one", parseJsonString(`{"rows": [0], "keys": ["i2"]}`)).run();
	assert(sel.rows == [1]);
	// a group of the tree
	at.selectGroup("one", "Bob").run();
	assert(sel.group == ["Bob"] && sel.rows.length == 0);
	at.selectGroup("one", "Nobody").run();
	assert(sel.empty);
	// multi-row: out-of-range rows are dropped, duplicates removed
	at.selectRows("many", 0, 2, 2, 9).run();
	assert(multiSel.rows == [0, 2]);
	// single cell
	at.setValueById("k:cell", parseJsonString(`{"cells": [[1, "name"]]}`)).run();
	assert(cell.cells.length == 1 && cell.cells[0].row == 1 && cell.cells[0].column == "name");
	at.setValueById("k:cell", parseJsonString(`{"cells": [[1, "nope"]]}`)).run();
	assert(cell.cells.length == 0);
	auto bad = new AppTest((St st) { st.dataframe(df, onSelect: "rerun", selectionMode: "all"); }).run();
	assert(bad.exceptions.length == 1);
	auto bad2 = new AppTest((St st) { st.dataframe(df, groupBy: ["nope"]); }).run();
	assert(bad2.exceptions.length == 1);
}

// ---------------------------------------------------------------- context, widget behaviours, navigation, small elements, lazy downloads

unittest
{
	RequestContext seen;
	auto at = new AppTest((St st) { seen = st.context; });
	RequestContext c;
	c.headers = ["user-agent": "Test/1.0"];
	c.cookies = ["airop_token": "abc"];
	c.ip = "10.0.0.7";
	c.locale = "ru-RU";
	at.setContext(c).run();
	assert(seen.header("User-Agent") == "Test/1.0" && seen.cookie("airop_token") == "abc" && seen.cookie("nope") is null);
	assert(seen.ip == "10.0.0.7" && seen.locale == "ru-RU");
	// the browser reports language, time zone and URL with its messages
	at.sess.handleClientMessage(parseJsonString(`{"type": "rerun", "client": {"timezone": "Asia/Almaty", "timezoneOffset": 300,
		"url": "http://h/x", "locale": "kk-KZ"}}`));
	at.run();
	assert(seen.timezone == "Asia/Almaty" && seen.timezoneOffset == 300 && seen.url == "http://h/x" && seen.locale == "kk-KZ");
}

unittest
{
	// required segmented control / pills: always one option; null from the browser keeps it
	string seg, pill;
	auto at = new AppTest((St st) {
		seg = st.segmentedControl("View", ["A", "B"], key: "v", required: true);
		pill = st.pills("Kind", ["x", "y"], 1, required: true);
	}).run();
	assert(seg == "A" && pill == "y");
	assert(at.widget("segmented_control", "View")["required"].get!bool);
	at.setValue("segmented_control", "View", Json(null)).run();
	assert(seg == "A");
	at.setValue("segmented_control", "View", Json(1)).run();
	assert(seg == "B");
	at.setValue("segmented_control", "View", Json(null)).run();
	assert(seg == "A"); // the default again, never nothing
}

unittest
{
	// keyed widgets keep their value while they are not drawn (another page); resetWidgets forgets it
	bool draw = true, reset;
	string name;
	auto at = new AppTest((St st) {
		if (reset) { st.resetWidgets("name"); reset = false; }
		if (draw) name = st.textInput("Name", "default", key: "name");
	}).run();
	at.setValue("text_input", "Name", Json("Ann")).run();
	assert(name == "Ann");
	draw = false;
	at.run();
	draw = true;
	at.run();
	assert(name == "Ann"); // remembered across the run without the widget
	reset = true;
	at.run();
	assert(name == "default");
	// a toast shown before st.rerun() still reaches the browser
	auto t = new AppTest((St st) {
		if (st.button("Save")) { st.toast("Saved"); st.rerun(); }
	}).run();
	t.click("Save").run();
	assert(t.messages("toast").length == 1 && t.messages("toast")[0]["body"].get!string == "Saved");
}

unittest
{
	// small elements: their JSON and their checks
	auto at = new AppTest((St st) {
		st.metric("Fact", "5,510 €", "+4%", chartData: [1.0, 2, 3], chartType: "area", caption: "was 5,288");
		st.emptyState("Nothing", "Try another filter.");
		st.legend([LegendItem("Late", "error", "circle"), LegendItem("On time")], "Colours");
		st.proportionBar([1.0, 3.0], ["a", "b"], ["error", "#00ff00"], format: "%d");
		st.feed([FeedItem("Overdue", "**21** days", "09:12", "error", true, null, ["ACME"])]);
		st.details([["Suppliers", "4"]], inline: true);
		st.card("Suppliers", link: "suppliers").caption("x");
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto m = at.elements("metric")[0];
	assert(m["chartData"].length == 3 && m["chartType"].get!string == "area" && m["caption"].get!string == "was 5,288");
	assert(at.elements("empty_state")[0]["title"].get!string == "Nothing");
	assert(at.elements("legend")[0]["items"][1]["shape"].get!string == "square");
	assert(at.elements("proportion_bar")[0]["colors"][1].get!string == "#00ff00");
	auto f = at.elements("feed")[0]["items"][0];
	assert(f["unread"].get!bool && f["badges"][0].get!string == "ACME" && f["type"].get!string == "error");
	assert(at.elements("details")[0]["inline"].get!bool);
	assert(at.elements("block").filter!(b => b["block"].get!string == "card").front["link"].get!string == "suppliers");
	foreach (bad; [
		(St st) { st.legend([LegendItem("x", null, "star")]); },
		(St st) { st.proportionBar([1.0], ["a", "b"]); },
		(St st) { st.proportionBar([-1.0], ["a"]); },
		(St st) { st.feed([FeedItem("x", null, null, "purple")]); },
		(St st) { st.metric("x", "1", chartType: "pie"); },
		(St st) { st.navigation([Page((St s) {}, "A")], sections: "folded"); },
	])
		assert(new AppTest(bad).run().exceptions.length == 1);
	// navigation: badges and collapsible sections reach the browser
	auto nav = new AppTest((St st) {
		st.navigation([Page((St s) {}, "Home"), Page((St s) {}, "Inbox", section: "Mail", badge: "3")], sections: "collapsible").run(st);
	}).run();
	auto msg = nav.messages("navigation")[0];
	assert(msg["sections"].get!string == "collapsible" && msg["pages"][1]["badge"].get!string == "3");
}

unittest
{
	// downloads built on click: the button links to a token; the build runs only when asked
	int built;
	bool draw = true;
	auto at = new AppTest((St st) {
		if (draw)
			st.downloadButton("Export", () { built++; return "a,b\n1,2\n"; }, "x.csv", "text/csv");
	}).run();
	assert(built == 0);
	auto el = at.elements("download_button")[0];
	assert(el["lazy"].get!bool);
	auto url = el["url"].get!string;
	import std.algorithm : startsWith;
	assert(url.startsWith("_stcore/download/"));
	auto tok = url["_stcore/download/".length .. $];
	auto d = at.sess.lazyDownload(tok);
	assert(d !is null && cast(string) d.build() == "a,b\n1,2\n" && built == 1 && d.fileName == "x.csv");
	at.run();
	assert(at.elements("download_button")[0]["url"].get!string == url); // the same link on every run
	draw = false;
	at.run();
	assert(at.sess.lazyDownload(tok) is null); // gone with the button
}

// ---------------------------------------------------------------- calendar grid, nested dialogs

unittest
{
	import std.datetime : Date;
	GridEvent ev;
	auto rows = [GridRow("acme", "ACME", null, "1 / 2", 0.5, 0.6), GridRow("rocket", "Rocket", "acme")];
	auto items = [GridItem("d1", "rocket", Date(2026, 11, 3), Date.init, "Delivery", 400),
		GridItem("p1", "rocket", Date(2026, 11, 5), Date(2026, 11, 9), "Payments")];
	auto at = new AppTest((St st) {
		ev = st.calendarGrid(rows, items, Date(2026, 11, 1), Date(2026, 11, 30), key: "plan", today: Date(2026, 11, 18),
			focus: "d1", expanded: 1);
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto el = at.elements("calendar_grid")[0];
	assert(el["rows"].length == 2 && el["items"][1]["end"].get!string == "2026-11-09" && el["focus"].get!string == "d1");
	assert(el["today"].get!string == "2026-11-18" && el["expanded"].get!long == 1);
	assert(!ev);
	at.trigger("plan", parseJsonString(`{"kind": "item", "item": "d1", "row": "rocket"}`)).run();
	assert(ev.kind == "item" && ev.item == "d1" && ev.date == Date(2026, 11, 3));
	at.run();
	assert(!ev); // like a button: only in the run of the click
	at.trigger("plan", parseJsonString(`{"kind": "cell", "row": "acme", "date": "2026-11-20"}`)).run();
	assert(ev.kind == "cell" && ev.row == "acme" && ev.date == Date(2026, 11, 20));
	at.trigger("plan", parseJsonString(`{"kind": "item", "item": "nope", "row": "rocket"}`)).run();
	assert(!ev);
	auto bad = new AppTest((St st) {
		st.calendarGrid([GridRow("a", "A")], [GridItem("x", "a", Date(2026, 1, 1), Date.init, null, double.nan, "star")],
			Date(2026, 1, 1), Date(2026, 1, 31));
	}).run();
	assert(bad.exceptions.length == 1);
}

unittest
{
	// a dialog opened while another dialog's body runs nests in it, also when the outer one reruns alone
	bool inner = true;
	int innerRuns;
	auto at = new AppTest((St st) {
		st.dialog("Outer", (St d) {
			d.text("outer body");
			auto b = d.button("Toggle");
			if (inner)
				st.dialog("Inner", (St e) { innerRuns++; e.text("inner body"); });
		});
	}).run();
	assert(at.exceptions.length == 0, at.exceptions.to!string);
	auto dialogs = at.elements("block").filter!(b => b["block"].get!string == "dialog").array;
	assert(dialogs.length == 2 && dialogs[1]["title"].get!string == "Inner");
	auto paths = at.paths("dialog");
	assert(paths.length == 2 && paths[1].length > paths[0].length && paths[1][0 .. paths[0].length] == paths[0], paths.to!string);
	// a click in the outer dialog reruns it alone; the inner one is drawn inside it again
	at.click("Toggle").run();
	auto again = at.paths("dialog");
	assert(again == paths && innerRuns == 2, again.to!string);
}

unittest
{
	// a dialog opened from a session value: onDismiss tells the app when the user closes it
	import std.exception : assertThrown;
	int dismissed;
	auto at = new AppTest((St st) {
		if (st.button("Edit"))
			st.session["editing"] = true;
		if (st.session.get!bool("editing", false))
			st.dialog("Edit item", (St d) { d.text("form"); }, onDismiss: { dismissed++; st.session.remove("editing"); });
		st.dialog("Plain", (St d) { d.text("x"); }, key: "plain");
	}).run();
	assert(at.paths("dialog").length == 1);
	assertThrown(at.dismissDialog("Plain")); // no onDismiss: the server never hears of it
	at.click("Edit").run();
	assert(at.paths("dialog").length == 2);
	at.dismissDialog("Edit item").run();
	assert(dismissed == 1 && !at.session.has("editing"));
	assert(at.paths("dialog").length == 1); // stays closed on later runs
	at.run();
	assert(at.paths("dialog").length == 1 && dismissed == 1);
}

unittest
{
	// with rowKey, the kept selection follows the keys: removing the selected rows empties it,
	// instead of selecting whatever rows now have those numbers
	string[] ids = ["a", "b", "c", "d"];
	TableSelection sel;
	auto at = new AppTest((St st) {
		sel = st.dataframe(new DataFrame().addColumn("id", ids), onSelect: "rerun", selectionMode: "multi-row",
			rowKey: "id", key: "t");
	}).run();
	at.selectRows("t", 0, 1).run();
	assert(sel.keys == [Json("a"), Json("b")]);
	ids = ["c", "d"]; // a and b are gone (e.g. completed and filtered out)
	at.run();
	assert(sel.empty, sel.rows.to!string);
	ids = ["d", "x", "b"];
	at.selectRows("t", 2).run(); // "b"
	ids = ["b", "d"];
	at.run();
	assert(sel.rows == [0] && sel.keys == [Json("b")]); // follows "b" to its new row
}

unittest
{
	// crafted selections (huge lists of rows or keys) cost time linear in the message, and never
	// select more rows than the frame has
	import std.datetime.stopwatch : StopWatch, AutoStart;
	import std.range : iota;
	auto ids = iota(5000).map!(i => "id" ~ i.to!string).array;
	TableSelection sel;
	auto at = new AppTest((St st) {
		sel = st.dataframe(new DataFrame().addColumn("id", ids), onSelect: "rerun", selectionMode: "multi-row",
			rowKey: "id", key: "t");
	}).run();
	auto ks = Json.emptyArray;
	foreach (i; 0 .. 200_000)
		ks.appendArrayElement(Json(i % 3 ? "nope" : "id" ~ (i % 5000).to!string));
	auto sw = StopWatch(AutoStart.yes);
	at.setValueById("k:t", Json(["keys": ks])).run();
	assert(sw.peek.total!"msecs" < 1500, sw.peek.toString);
	assert(sel.rows.length <= 5000 && sel.rows.length > 0);
	auto rs = Json.emptyArray;
	foreach (i; 0 .. 200_000)
		rs.appendArrayElement(Json(i % 5000));
	TableSelection plain;
	auto at2 = new AppTest((St st) {
		plain = st.dataframe(new DataFrame().addColumn("id", ids), onSelect: "rerun", selectionMode: "multi-row", key: "t");
	}).run();
	sw.reset();
	at2.setValueById("k:t", Json(["rows": rs])).run();
	assert(sw.peek.total!"msecs" < 1500, sw.peek.toString);
	assert(plain.rows.length == 5000 && plain.rows[0 .. 3] == [0, 1, 2]);
}

unittest
{
	// dataEditor(maxRows:): rows added beyond the limit are ignored
	DataFrame result;
	auto at = new AppTest((St st) {
		result = st.dataEditor(new DataFrame().addColumn("a", [1, 2]), key: "ed", numRows: "dynamic", maxRows: 3);
	}).run();
	assert(at.elements("data_editor")[0]["maxRows"].get!long == 3);
	auto added = Json.emptyArray;
	foreach (i; 0 .. 1000)
		added.appendArrayElement(Json(["a": Json(i)]));
	at.setValueById("k:ed", Json(["added": added])).run();
	assert(result.length == 3);
	at.setValueById("k:ed", Json(["added": added, "deleted": Json([Json(0)])])).run();
	assert(result.length == 3); // one deleted, two added
}

unittest
{
	// a keyed table without rowKey: a selection made on other rows is dropped (indices would point elsewhere)
	auto big = new DataFrame().addColumn("a", [1, 2, 3, 4]);
	auto small = new DataFrame().addColumn("a", [1, 2]);
	bool useSmall;
	TableSelection sel;
	auto at = new AppTest((St st) { sel = st.dataframe(useSmall ? small : big, onSelect: "rerun", key: "t"); }).run();
	at.setValueById("k:t", parseJsonString(`{"rows": [1], "n": 4}`)).run();
	assert(sel.rows == [1]);
	at.run();
	assert(sel.rows == [1]); // same rows: kept
	useSmall = true;
	at.run();
	assert(sel.empty, sel.rows.to!string);
	assert(at.elements("dataframe")[0]["memoKey"].get!string == "t:t");
}


// ---------------------------------------------------------------- cacheData hands out copies (shared by all sessions)

DataFrame sharedFrame(string p) { return new DataFrame().addColumn("a", [1, 2, 3]); }

unittest
{
	// one session adds rows to its copy; the cached frame and other sessions do not see them
	size_t lenA, lenB;
	bool add;
	auto a = new AppTest((St st) {
		auto df = cacheData!sharedFrame("x");
		foreach (row; st.session.get!(Json[][])("added"))
			df.appendRow(row);
		if (add)
		{
			st.session["added"] = st.session.get!(Json[][])("added") ~ [[Json(9)]];
			add = false;
			st.rerun();
		}
		lenA = df.length;
	});
	auto b = new AppTest((St st) { lenB = cacheData!sharedFrame("x").length; });
	add = true;
	a.run();
	b.run();
	assert(lenA == 4 && lenB == 3, [lenA, lenB].to!string);
	assert(cacheData!sharedFrame("x") !is cacheData!sharedFrame("x"));
}
