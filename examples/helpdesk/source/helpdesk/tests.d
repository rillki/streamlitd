/// Unit tests of the helpdesk: the store and the pages, without a browser (`dub test`).
module helpdesk.tests;

version (unittest):

import std.algorithm : canFind, count, all;
import std.file : exists, remove, tempDir;
import std.path : buildPath;
import streamlitd;
import streamlitd.testing;
import helpdesk.store;
import helpdesk.pages.tickets;
import helpdesk.pages.customers;
import helpdesk.ui : agents;
import helpdesk.pages.dashboard;
import helpdesk.pages.admin;

/// A fresh in-memory store (no file, no push to open pages) for each test.
private Store fresh()
{
	auto s = new Store(null, false);
	useStore(s);
	return s;
}

unittest // seed data and changes; the file survives a reload
{
	auto path = buildPath(tempDir, "helpdesk-unittest.json");
	if (path.exists) remove(path);
	scope (exit) if (path.exists) remove(path);
	auto s = new Store(path, false);
	assert(s.tickets.length == 24 && s.customers.length == 6);
	auto t = s.add("bob", "Printer on fire", "acme", "urgent");
	assert(t.id == 25 && t.isOpen && t.assignee == "");
	assert(s.update(t.id, "bob", "took it", (ref Ticket x) { x.assignee = "bob"; }));
	assert(!s.update(999, "bob", "nothing", (ref Ticket x) {}));
	auto again = new Store(path, false);
	assert(again.ticket(25).assignee == "bob" && again.tickets.length == 25);
	assert(again.activity(1)[0].what.canFind("took it"));
}

unittest // filters
{
	auto s = fresh();
	auto all_ = s.tickets;
	assert(filtered(all_, s, "active", null, "anyone", "").all!(t => t.isOpen));
	assert(filtered(all_, s, "all", null, "anyone", "").length == 24);
	assert(filtered(all_, s, "all", ["urgent"], "nobody", "").all!(t => t.priority == "urgent" && !t.assignee.length));
	assert(filtered(all_, s, "all", null, "anyone", "#0003").length == 1);
	assert(filtered(all_, s, "all", null, "anyone", "acme").all!(t => t.customer == "acme"));
}

unittest // customer checks
{
	assert(!customerProblems([Customer("a", "A", "free", 1, "x@y")]).length);
	assert(customerProblems([Customer("a", "", "free", 1, "")]).length == 1);
	assert(customerProblems([Customer("a", "A", "free", 1, ""), Customer("b", "A", "free", 1, "")]).length == 1);
	assert(customerProblems([Customer("a", "A", "free", 1, "nope")]).length == 1);
}

unittest // tickets page: select a ticket, change its status, see it saved
{
	auto s = fresh();
	auto at = new AppTest(&tickets).loginAs("bob", ["agent"]).run();
	assert(!at.exceptions.length);
	assert(at.markdowns.canFind("Select a ticket to see it here."));
	auto first = s.tickets[0]; // "active" filter: the first open ticket is the first row
	at.selectRows("ticket-table", 0).run();
	assert(at.headings.canFind!(h => h.canFind("#" ~ idText(first.id))));
	at.setValue("selectbox", "Change status", Json(2)).run(); // "solved"
	at.click("Save changes").run();
	assert(!at.exceptions.length);
	assert(s.ticket(first.id).status == "solved");
	assert(s.activity(1)[0].who == "bob");
}

unittest // tickets page: the edit dialog and its nested confirmation close a ticket
{
	auto s = fresh();
	auto at = new AppTest(&tickets).loginAs("alice", ["admin", "agent"]).run();
	auto first = s.tickets[0];
	at.selectRows("ticket-table", 0).run();
	at.click("Edit…").run();
	assert(at.paths("dialog").length == 1);
	at.click("Close ticket…").run();
	assert(at.paths("dialog").length == 2); // the confirmation opens on top
	at.click("Yes, close it").run();
	assert(s.ticket(first.id).status == "closed");
	assert(at.paths("dialog").length == 0);
}

unittest // closing the dialog with × or Esc is remembered: it does not open again
{
	fresh();
	auto at = new AppTest(&tickets).run();
	at.selectRows("ticket-table", 0).run();
	at.click("Edit…").run();
	auto title = "Edit #" ~ idText(store.tickets[0].id);
	at.dismissDialog(title).run();
	assert(at.paths("dialog").length == 0);
	at.run();
	assert(at.paths("dialog").length == 0);
}

unittest // filters with no match show an empty state
{
	fresh();
	auto at = new AppTest(&tickets).run();
	at.setValue("text_input", "Search", Json("no such ticket")).run();
	assert(at.elements("empty_state").length == 1);
}

unittest // dashboard counts
{
	auto s = fresh();
	auto at = new AppTest(&dashboard).run();
	assert(!at.exceptions.length);
	auto open = s.tickets.count!(t => t.isOpen);
	assert(at.elements("metric").length == 3);
	assert(at.elements("metric")[0]["value"].get!string == open.to!string);
	// counts start at 0, not NaN: the status bar adds up to every ticket
	double sum = 0;
	foreach (v; at.elements("proportion_bar")[0]["values"])
		sum += v.to!double;
	assert(sum == 24);
}

unittest // the users page is for admins only
{
	fresh();
	auto at = new AppTest(&admin).loginAs("bob", ["agent"]).run();
	assert(!at.headings.canFind("Users"));
	assert(at.alerts.length >= 1);
}

private import std.conv : to;

unittest // hostile input: invalid tickets are refused, typed text never becomes Markdown
{
	import std.array : replicate;
	import std.exception : assertThrown;
	auto s = fresh();
	assert(s.problemOf("ok", "acme", "high") is null);
	assert(s.problemOf("ok", "acme", "apocalyptic").canFind("priority"));
	assert(s.problemOf("ok", "no-such-customer", "high").canFind("unknown customer"));
	assert(s.problemOf("  ", "acme", "high").canFind("required"));
	assert(s.problemOf("x".replicate(201), "acme", "high").canFind("longer"));
	assertThrown(s.add("bob", "x", "acme", "apocalyptic"));
	// a title with an image, a link and a colour directive is shown as text
	auto t = s.add("bob", "![x](http://evil.example/p.png) :red[urgent]", "acme", "high");
	assert(s.activity(1)[0].what.canFind(`\!\[x\]`) && !s.activity(1)[0].what.canFind("!["));
	auto at = new AppTest(&tickets).loginAs("bob", ["agent"]).run();
	at.setValue("text_input", "Search", Json("evil")).run();
	at.selectRows("ticket-table", 0).run();
	assert(at.headings.canFind!(h => h.canFind(`\!\[x\]`) && h.canFind("&#58;red")), at.headings.to!string);
}

unittest // new customers get unused ids, also after deletions
{
	auto s = fresh();
	auto cs = s.customers[0 .. 2] ~ [Customer(null, "New A", "free", 1, null), Customer(null, "New B", "free", 1, null)];
	assignIds(cs);
	assert(cs[2].id == "c1" && cs[3].id == "c2");
	s.saveCustomers("ann", cs);
	auto again = s.customers[0 .. 3] ~ [Customer(null, "New C", "free", 1, null)]; // c2 deleted, one added
	assignIds(again);
	assert(again[3].id == "c3"); // not c2, deleted in this very edit: tickets may still point at it
	bool[string] seen;
	foreach (c; again)
	{
		assert(c.id !in seen);
		seen[c.id] = true;
	}
}

unittest // the assignee lists come from the users (the demo agents without accounts)
{
	fresh();
	auto at = new AppTest(&tickets).loginAs("alice", ["admin", "agent"]).run();
	auto opts = at.widget("selectbox", "Assignee")["options"];
	assert(opts.length == 4 && opts[2].get!string == "alice");
}
