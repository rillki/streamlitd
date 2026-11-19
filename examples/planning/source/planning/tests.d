/// Unit tests of the planning app: the store, the import, and the pages without a browser.
module planning.tests;

version (unittest):

import std.algorithm : canFind, count, filter, map;
import std.array : array;
import std.conv : to;
import std.datetime : Date;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import streamlitd;
import streamlitd.testing;
import planning.store;
import planning.ui;
import planning.pages.plan;
import planning.pages.actuals;
import planning.pages.deliveries;
import planning.pages.imports;

/// A fresh in-memory store on a fixed day (Jan–Oct closed).
private Store fresh()
{
	useToday(Date(2026, 11, 18));
	auto s = new Store(null, false);
	useStore(s);
	return s;
}

unittest // seed, save with a diff, closed months kept, the version check, reload from the file
{
	useToday(Date(2026, 11, 18));
	auto path = buildPath(tempDir, "planning-unittest.json");
	if (path.exists) remove(path);
	scope (exit) if (path.exists) remove(path);
	auto s = new Store(path, false);
	assert(s.brands.length == 7 && s.suppliers.length == 4 && s.deliveries.length == 21);
	assert(s.brands[0].fact[9] > 0 && s.brands[0].fact[10] == 0); // Oct closed, Nov open

	auto next = s.brands;
	next[0].plan[11] += 100;           // Dec: open
	next[0].plan[0] = 1;               // Jan: closed, ignored on save
	next = next[0 .. $ - 1];           // remove the last brand
	next ~= Brand(null, "acme", "Rocket Mini");
	next[$ - 1].plan[11] = 500;
	auto changes = s.diff(next);
	assert(changes.count!(c => c.kind == "changed") == 2);
	assert(changes.canFind!(c => c.kind == "added" && c.brand == "Rocket Mini"));
	assert(changes.canFind!(c => c.kind == "removed" && c.brand == "Shield"));

	auto v = s.version_no;
	assert(s.savePlan(next, v));
	assert(!s.savePlan(next, v)); // somebody saved in between: refused
	auto b = s.brands[0];
	assert(b.plan[11] == next[0].plan[11] && b.plan[0] != 1 && b.fact[0] > 0);
	assert(s.deliveries.length == 18); // Shield's deliveries went with it

	auto again = new Store(path, false);
	assert(again.brands.length == 7 && again.version_no == v + 1);
	assert(again.brands.canFind!(x => x.name == "Rocket Mini" && x.id.length));
}

unittest // reading the edited table back
{
	auto s = fresh();
	string[] problems;
	auto df = planFrame(s);
	assert(brandsFrom(df, s, problems).length == 7 && !problems.length);
	Json[] row0;
	foreach (c; df.columns)
		row0 ~= df.cell(0, c);
	auto bad = DataFrame.fromRows(df.columns.dup, [row0, row0, [Json("Nobody"), Json("X")] ~ row0[2 .. $]]);
	brandsFrom(bad, s, problems);
	assert(problems.length == 2 && problems[0].canFind("twice") && problems[1].canFind("supplier"));
}

unittest // the import: parse, guess names, preview
{
	auto s = fresh();
	string[] problems;
	assert(parseImport("a,b\n1,2\n", problems) is null && problems.length == 4);
	problems = null;
	parseImport("supplier,brand,month,amount\nACME,Rocket,13,5\nACME,Rocket,x,5\n", problems);
	assert(problems.length == 2, problems.to!string);
	problems = null;
	auto rows = parseImport(sampleCsv, problems);
	assert(rows.length == 6 && !problems.length);

	assert(guessSupplier("ACME Corporation", s.suppliers) == "ACME");
	assert(guessSupplier("initech ltd", s.suppliers) == "Initech");
	assert(guessSupplier("Hooli", s.suppliers) is null);

	auto pv = previewImport(rows, ["ACME Corporation": "ACME", "Initech Ltd": "Initech", "Hooli": newSupplier], s);
	assert(pv.count!(c => c.kind == "changed") == 4, pv.to!string); // Rocket, Gizmo, Stapler, Printer
	assert(pv.canFind!(c => c.kind == "added" && c.brand == "Rocket Mini" && c.note == "new brand"));
	assert(pv.canFind!(c => c.kind == "added" && c.supplier == "Hooli" && c.note == "new supplier"));
	auto closed = previewImport([ImportRow("ACME", "Rocket", 3, 1)], null, s);
	assert(closed[0].kind == "skipped");
}

unittest // the import wizard, step by step
{
	auto s = fresh();
	auto at = new AppTest(&importPage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	at.click("Use the sample file").run();
	assert(at.elements("selectbox").length == 3); // ACME Corporation, Hooli, Initech Ltd
	assert(at.widget("selectbox", "“ACME Corporation” is")["value"].get!long == 0); // guessed: ACME
	at.click("Next").run();
	assert(at.elements("metric")[0]["value"].get!string == "2"); // Rocket Mini and Hooli's Phone
	at.click("Apply").run();
	assert(at.alerts.canFind!(a => a.canFind("Imported 6 plan cells")));
	assert(s.suppliers.canFind!(x => x.name == "Hooli"));
	assert(s.brands.canFind!(b => b.name == "Rocket Mini" && b.plan[11] == 800));
	at.click("Import another file").run();
	assert(at.elements("file_uploader").length == 1);
}

unittest // the plan page: an edit, the review dialog, saved; a closed month can't be changed
{
	auto s = fresh();
	auto at = new AppTest(&planPage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	auto id = at.widgetId("data_editor", null);
	auto before = s.brands[0].plan;
	at.setValueById(id, parseJsonString(`{"edited": {"0": {"m12": 999, "m01": 5}}}`)).run();
	at.click("Review & save").run();
	assert(at.paths("dialog").length == 1);
	assert(at.elements("dataframe")[0]["data"].length == 1); // only December: January is closed
	at.click("Save").run();
	assert(s.brands[0].plan[11] == 999 && s.brands[0].plan[0] == before[0]);
	assert(at.paths("dialog").length == 0);
}

unittest // someone else saves while this user edits
{
	auto s = fresh();
	auto at = new AppTest(&planPage).run();
	auto id = at.widgetId("data_editor", null);
	at.setValueById(id, parseJsonString(`{"edited": {"1": {"m12": 1}}}`)).run();
	auto other = s.brands;
	other[2].plan[11] = 7;
	assert(s.savePlan(other, s.version_no));
	at.run();
	assert(at.alerts.canFind!(a => a.canFind("Someone else saved the plan")));
	at.click("Load the latest plan").run();
	assert(!at.alerts.canFind!(a => a.canFind("Someone else")));
}

unittest // plan vs fact and the deliveries calendar
{
	auto s = fresh();
	auto df = actualsFrame(s);
	assert(df.length == 7);
	auto at = new AppTest(&actualsPage).run();
	assert(!at.exceptions.length, at.exceptions.to!string);
	at.selectRows("actuals", 0).run();
	assert(at.elements("vega_lite").length == 1);

	GridRow[] rows;
	GridItem[] items;
	gridData(s, today, rows, items);
	assert(rows.length == 11 && items.length == 21);
	assert(items.canFind!(i => i.color == "error")); // a late one in the seed
	auto cal = new AppTest(&deliveriesPage).run();
	assert(!cal.exceptions.length, cal.exceptions.to!string);
	auto late = items.filter!(i => i.color == "error").front;
	cal.trigger("deliveries", Json(["kind": Json("item"), "item": Json(late.id), "row": Json(late.row)])).run();
	assert(cal.paths("dialog").length == 1);
	cal.click("Mark delivered").run();
	assert(s.deliveries.filter!(d => d.id == late.id).front.delivered);
	// an empty day of a brand: plan a delivery there
	cal.trigger("deliveries", Json(["kind": Json("cell"), "row": Json("b1"), "date": Json("2026-12-10")])).run();
	cal.click("Plan it").run();
	assert(s.deliveries.length == 22);
}

unittest // hostile input: absurd amounts and months are refused, names are shown as text
{
	import std.exception : assertThrown;
	auto s = fresh();
	string[] problems;
	parseImport("supplier,brand,month,amount\nACME,Rocket,12,1e308\nACME,Rocket,12.5,1\nACME,Rocket,nan,1\nACME,Rocket,12,-1\n", problems);
	assert(problems.length == 4, problems.to!string);
	problems = null;
	import std.array : replicate;
	assert(parseImport("supplier,brand,month,amount\n" ~ "A,B,12,1\n".replicate(maxImportRows + 1), problems) is null
		&& problems[0].canFind("at most"));
	assertThrown(s.applyCells([["acme", "Rocket", "12"]], [double.infinity]));
	auto next = s.brands;
	next[0].plan[11] = 1e12;
	assertThrown(s.savePlan(next, s.version_no));
	// a brand named like Markdown is shown as text
	next = s.brands;
	next[0].name = "![x](http://evil.example/p.png)";
	assert(s.savePlan(next, s.version_no));
	auto at = new AppTest(&actualsPage).run();
	at.selectRows("actuals", 0).run();
	assert(at.headings.canFind!(h => h.canFind(`\!\[x\]`)), at.headings.to!string);
}

unittest // renaming a brand in the editor keeps its fact and deliveries
{
	auto s = fresh();
	auto at = new AppTest(&planPage).run();
	auto id = at.widgetId("data_editor", null);
	auto before = s.brands[0];
	auto deliveries = s.deliveries.count!(d => d.brand == before.id);
	at.setValueById(id, parseJsonString(`{"edited": {"0": {"brand": "Rocket XL"}}}`)).run();
	at.click("Review & save").run();
	auto changes = at.elements("dataframe")[0]["data"];
	assert(changes.length == 1 && changes[0][0].get!string == "renamed", changes.toString);
	at.click("Save").run();
	auto after = s.brand(before.id);
	assert(after.name == "Rocket XL" && after.fact == before.fact);
	assert(s.deliveries.count!(d => d.brand == before.id) == deliveries && deliveries > 0);
}
