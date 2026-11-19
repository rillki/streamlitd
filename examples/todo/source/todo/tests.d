/// Unit tests of the TODO app (`dub test`).
module todo.tests;

version (unittest):

import std.algorithm : canFind, count, filter, map;
import std.array : array;
import std.conv : to;
import std.datetime : Date;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import streamlitd;
import streamlitd.testing;
import todo.store;
import todo.ui;
import todo.pages.tasks;
import todo.pages.lists;

private Store fresh()
{
	useToday(Date(2026, 11, 18));
	auto s = new Store(null, false);
	useStore(s);
	return s;
}

unittest // boards are per user, saved to the file
{
	useToday(Date(2026, 11, 18));
	auto path = buildPath(tempDir, "todo-unittest.json");
	if (path.exists) remove(path);
	scope (exit) if (path.exists) remove(path);
	auto s = new Store(path, false);
	assert(s.board("ann").tasks.length == 9 && s.board("ann").lists.length == 3);
	auto t = s.add("ann", Task(0, "home", "Water the plants"));
	s.update("ann", [t.id], (ref Task x) { x.done = true; });
	assert(s.board("bob").tasks.length == 9); // bob's board is his own
	auto again = new Store(path, false);
	assert(again.board("ann").tasks.canFind!(x => x.title == "Water the plants" && x.done));
	auto l = again.addList("ann", "Shopping", "🛒");
	again.removeList("ann", "inbox"); // the inbox stays
	again.removeList("ann", "home");
	assert(again.board("ann").lists.map!(x => x.id).array == ["inbox", "work", l]);
	assert(!again.board("ann").tasks.canFind!(x => x.list == "home"));
}

unittest // quick add syntax
{
	useToday(Date(2026, 11, 18));
	auto t = parseQuick("Call Anna #phone #Work !high ^tomorrow");
	assert(t.title == "Call Anna" && t.tags == ["phone", "work"] && t.priority == "high" && t.due == "2026-11-19");
	assert(parseQuick("Pay rent ^2026-12-01 !urgent").title == "Pay rent !urgent"); // unknown priority stays text
	assert(parseQuick("Pay rent ^2026-12-01").due == "2026-12-01");
	assert(parseQuick("^someday").title == "^someday");
}

unittest // views and ordering
{
	auto s = fresh();
	auto b = s.board("ann");
	auto t = today;
	assert(inScope(b, "today", t).map!(x => x.title).array.canFind("Send the quarterly report")); // overdue counts
	assert(inScope(b, "upcoming", t).all!(x => x.dueDate > t));
	auto work = shown(inScope(b, "work", t), "Open", null, "");
	assert(work[0].title == "Send the quarterly report"); // earliest due first
	assert(shown(inScope(b, "home", t), "Done", null, "").length == 1);
	assert(shown(inScope(b, "work", t), "All", ["reports"], "").length == 2);
	assert(shown(inScope(b, "work", t), "All", null, "PULL").length == 1);
	assert(metaLine(work[0], t).canFind(":red[") && metaLine(work[0], t).canFind(":red-badge[high]"));
}

unittest // the page: quick add, the done checkbox, the edit dialog
{
	auto s = fresh();
	auto at = new AppTest((St st) { taskView(st, "work", "Work"); }).loginAs("ann").run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	assert(at.elements("checkbox").length == 4);
	at.submitForm("Add", [at.widgetId("text_input", "New task"): Json("Write tests #code !high")]).run();
	auto added = s.board("ann").tasks.filter!(x => x.title == "Write tests").array;
	assert(added.length == 1 && added[0].list == "work" && added[0].priority == "high" && added[0].tags == ["code"]);
	assert(at.elements("checkbox").length == 5);
	// tick it
	at.setValue("checkbox", "Write tests", Json(true)).run();
	assert(s.board("ann").tasks.filter!(x => x.title == "Write tests").front.done);
	assert(at.elements("checkbox").length == 4); // "Open" hides it now
	// edit another task
	at.click("Edit").run(); // the first row's
	assert(at.paths("dialog").length == 1);
	at.setValue("text_input", "Title", Json("Send the Q4 report")).run();
	at.click("Save").run();
	assert(s.board("ann").tasks.canFind!(x => x.title == "Send the Q4 report"));
	assert(at.paths("dialog").length == 0);
}

unittest // bulk actions: select, delete after the confirmation
{
	auto s = fresh();
	auto at = new AppTest((St st) { taskView(st, "work", "Work"); }).loginAs("ann").run();
	at.setValue("toggle", "Select several", Json(true)).run();
	assert(at.elements("dataframe").length == 1);
	at.selectRows("bulk-table", 0, 1).run();
	at.click("Complete").run();
	assert(s.board("ann").tasks.count!(x => x.list == "work" && x.done) == 2);
	at.selectRows("bulk-table", 0).run();
	at.click("Delete…").run();
	assert(at.paths("dialog").length == 1);
	at.click("Delete").run();
	assert(s.board("ann").tasks.count!(x => x.list == "work") == 3);
}

unittest // the lists page
{
	auto s = fresh();
	auto at = new AppTest(&listsPage).loginAs("ann").run();
	at.submitForm("Add list", [at.widgetId("text_input", "Name"): Json("Garden")]).run();
	assert(s.board("ann").lists.canFind!(l => l.name == "Garden"));
	at.click("Delete").run(); // the first deletable one: Work
	at.click("Delete the list").run();
	assert(!s.board("ann").lists.canFind!(l => l.name == "Work"));
}

private import std.algorithm : all;

unittest // hostile input: tags hold only safe characters, titles are shown as text, limits hold
{
	import std.exception : assertThrown;
	auto s = fresh();
	auto t = parseQuick("hi #a]![x](http://evil.example/p.png) #B_2 #");
	assert(t.tags == ["axhttpevilexampleppng", "b_2"], t.tags.to!string);
	assert(!metaLine(t, today).canFind("](") && !metaLine(t, today).canFind("!["));
	s.add("ann", Task(0, "work", "![x](http://evil.example/p.png) :red[boss]"));
	auto at = new AppTest((St st) { taskView(st, "work", "Work"); }).loginAs("ann").run();
	auto labels = at.elements("checkbox").map!(e => e["label"].get!string).array;
	assert(labels.canFind!(l => l.canFind(`\!\[x\]`) && l.canFind("&#58;red")), labels.to!string);
	// limits per person
	foreach (i; s.board("ann").lists.length .. maxLists)
		s.addList("ann", "L" ~ i.to!string, "📝");
	assertThrown!LimitError(s.addList("ann", "one more", "📝"));
	s.change("ann", (ref Board x) { foreach (i; x.tasks.length .. maxTasks) x.tasks ~= Task(x.nextId++, "inbox", "t"); });
	assertThrown!LimitError(s.add("ann", Task(0, "inbox", "too many")));
	assert(s.board("bob").tasks.length == 9); // other people are not affected
}
