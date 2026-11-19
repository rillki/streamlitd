/// Unit tests of the project planner (`dub test`).
module gantt.tests;

version (unittest):

import core.time : days;
import std.algorithm : canFind, count, filter, map;
import std.array : array;
import std.conv : to;
import std.datetime : Date;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import streamlitd;
import streamlitd.testing;
import gantt.store;
import gantt.ui;
import gantt.pages.timeline;
import gantt.pages.table;

private Store fresh()
{
	useToday(Date(2026, 11, 18));
	auto s = new Store(null, false);
	useStore(s);
	return s;
}

unittest // the seed: statuses, one dependency problem; saving and removing
{
	useToday(Date(2026, 11, 18));
	auto path = buildPath(tempDir, "gantt-unittest.json");
	if (path.exists) remove(path);
	scope (exit) if (path.exists) remove(path);
	auto s = new Store(path, false);
	auto d = today;
	assert(s.tasks.length == 11 && s.phases.length == 4);
	assert(statusOf(s.task("t1"), d) == "done");
	assert(statusOf(s.task("t7"), d) == "late");
	assert(statusOf(s.task("t5"), d) == "behind");
	assert(statusOf(s.task("t9"), d) == "under way" || statusOf(s.task("t9"), d) == "behind");
	assert(statusOf(s.task("t10"), d) == "not started");
	auto cs = s.conflicts;
	assert(cs.length == 1 && cs[0].task.id == "t5" && cs[0].dependency.id == "t4");
	// move the visual design after the wireframes: no problem left
	auto t5 = s.task("t5");
	t5.start = (s.task("t4").endDate + 1.days).toISOExtString;
	s.put(t5);
	assert(!s.conflicts.length);
	s.remove("t4");
	assert(!s.task("t5").dependsOn.canFind("t4"));
	auto again = new Store(path, false);
	assert(again.tasks.length == 10 && again.task("t5").start == t5.start);
}

unittest // chart rows and bars
{
	auto s = fresh();
	GridRow[] rows;
	GridItem[] items;
	chartData(s, today, rows, items);
	assert(rows.length == 15 && items.length == 11);
	assert(items.count!(i => i.shape == "diamond") == 3);
	assert(items.filter!(i => i.id == "t7").front.color == "error");
	assert(rows[0].summary == "100% done"); // discovery
}

unittest // a click on a bar opens the editor; the dates change; a warning when they clash
{
	auto s = fresh();
	auto at = new AppTest(&timelinePage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	assert(at.alerts.canFind!(a => a.canFind("Visual design")));
	at.trigger("gantt", Json(["kind": Json("item"), "item": Json("t5"), "row": Json("t5")])).run();
	assert(at.paths("dialog").length == 1);
	assert(at.alerts.canFind!(a => a.canFind("Starts before “Wireframes” ends")));
	auto after = s.task("t4").endDate + 1.days;
	at.setValue("date_range_input", "Dates", Json([Json(after.toISOExtString), Json((after + 9.days).toISOExtString)])).run();
	at.click("Save").run();
	assert(s.task("t5").startDate == after && !s.conflicts.canFind!(c => c.task.id == "t5"));
	// moving it later pushes into what depends on it: those are listed now
	assert(s.conflicts.map!(c => c.task.name).array == ["Design review", "Frontend"]);
	assert(at.paths("dialog").length == 0);
}

unittest // an empty day: a new task in that row's phase; delete it again with the nested confirmation
{
	auto s = fresh();
	auto at = new AppTest(&timelinePage).run();
	at.trigger("gantt", Json(["kind": Json("cell"), "row": Json("t8"), "date": Json("2026-12-01")])).run();
	assert(at.paths("dialog").length == 1);
	at.setValue("text_input", "Name", Json("Accessibility check")).run();
	at.click("Add").run();
	auto t = s.tasks.filter!(x => x.name == "Accessibility check").front;
	assert(t.phase == "build" && t.start == "2026-12-01" && t.end == "2026-12-05");
	at.trigger("gantt", Json(["kind": Json("item"), "item": Json(t.id), "row": Json(t.id)])).run();
	at.click("Delete…").run();
	assert(at.paths("dialog").length == 2);
	at.click("Delete").run();
	assert(!s.task(t.id).id.length && at.paths("dialog").length == 0);
}

unittest // the table: grouped, a click opens the editor once
{
	auto s = fresh();
	auto df = taskFrame(s);
	assert(df.length == 11 && df.cell(2, "task").get!string == "◆ Requirements signed off");
	auto at = new AppTest(&tablePage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	at.selectRows("task-table", 6).run(); // Content migration
	assert(at.paths("dialog").length == 1);
	at.dismissDialog("Edit task").run();
	assert(at.paths("dialog").length == 0);
	at.run(); // still selected, but it stays closed
	assert(at.paths("dialog").length == 0);
}

unittest // hostile input: tasks that can't be drawn are refused; stored ones can't break the chart
{
	import std.exception : assertThrown;
	auto s = fresh();
	auto t = s.task("t1");
	foreach (bad; [["9999-12-31", "9999-12-31"], ["2026-11-20", "2026-11-10"], ["not a date", "2026-11-10"]])
	{
		auto x = t;
		x.start = bad[0];
		x.end = bad[1];
		assert(s.problemOf(x).length, bad.to!string);
		assertThrown(s.put(x));
	}
	auto y = t;
	y.progress = double.nan;
	assert(s.problemOf(y).length);
	y = t;
	y.dependsOn = ["t1"]; // itself
	assert(s.problemOf(y).length);
	y = t;
	y.assignee = "mallory";
	assert(s.problemOf(y).length);
	// even with a bad task in the file, the page draws
	s.change_for_tests((ref GTask[] ts) { ts[0].end = "9999-12-31"; });
	auto at = new AppTest(&timelinePage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	// names are shown as text
	auto z = s.task("t4"); // Wireframes: named in the scheduling problem above the chart
	z.name = "![x](http://evil.example/p.png)";
	s.put(z);
	at.run();
	assert(at.alerts.canFind!(a => a.canFind(`\!\[x\]`)) && !at.alerts.canFind!(a => a.canFind("![")), at.alerts.to!string);
}
