/// Customers: an editable table with typed columns, checked before it is saved.
module helpdesk.pages.customers;

import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.string : strip;
import streamlitd;
import helpdesk.store;
import helpdesk.ui;

/// Give new customers (no id yet) the next free ids `c1`, `c2`, ... An id is never reused for
/// another customer: tickets point at customers by id.
package(helpdesk) void assignIds(Customer[] cs)
{
	bool[string] used;
	foreach (c; cs)
		if (c.id.length)
			used[c.id] = true;
	foreach (c; store.customers) // also ids of customers deleted in this edit
		used[c.id] = true;
	foreach (t; store.tickets) // and of customers deleted earlier that tickets still point at
		used[t.customer] = true;
	int n = 1;
	foreach (ref c; cs)
		if (!c.id.length)
		{
			while (("c" ~ n.to!string) in used)
				n++;
			c.id = "c" ~ n.to!string;
			used[c.id] = true;
		}
}

/// Problems of an edited customer list (empty = fine to save).
package(helpdesk) string[] customerProblems(Customer[] cs)
{
	string[] problems;
	bool[string] names;
	foreach (c; cs)
	{
		if (!c.name.strip.length) problems ~= "A customer has no name.";
		else if (c.name.strip in names) problems ~= "The name \"" ~ c.name ~ "\" is used twice.";
		names[c.name.strip] = true;
		if (c.email.length && !c.email.canFind("@")) problems ~= c.name ~ ": \"" ~ c.email ~ "\" is not an email address.";
	}
	return problems;
}

void customers(St st)
{
	st.title("Customers");
	auto s = store;
	auto cs = s.customers;
	Json[][] rows;
	foreach (c; cs)
		rows ~= [Json(c.id), Json(c.name), Json(c.plan), Json(c.seats), Json(c.email)];
	auto df = DataFrame.fromRows(["id", "name", "plan", "seats", "email"], rows);
	auto edited = st.dataEditor(df, key: "customers-editor", numRows: "dynamic", hideIndex: true, maxRows: 500, columnConfig: [
		"id": C.text("Id", disabled: true),
		"name": C.text("Name", required: true, maxChars: 100),
		"plan": C.select("Plan", plans.dup, required: true),
		"seats": C.number("Seats", min: 1, max: 1000, step: 1),
		"email": C.text("Email", width: "medium", maxChars: 254),
	]);
	Customer[] next;
	foreach (r; 0 .. edited.length)
	{
		string str(string col) { auto v = edited.cell(r, col); return v.type == Json.Type.string ? v.get!string : null; }
		auto seats = edited.cell(r, "seats");
		next ~= Customer(str("id"), str("name"), str("plan").length ? str("plan") : "free",
			seats.type == Json.Type.int_ ? cast(int) seats.get!long : 1, str("email"));
	}
	assignIds(next);
	auto problems = customerProblems(next);
	foreach (p; problems)
		st.warning(escapeMarkdown(p)); // problems quote what was typed
	auto cols = st.columns([1.0, 1.2, 6]);
	if (cols[0].button("Save", type: "primary", disabled: problems.length > 0))
	{
		s.saveCustomers(me(st), next);
		st.resetWidgets("customers-editor"); // the editor shows the saved list again
		st.toast("Saved " ~ next.length.to!string ~ " customers", "✅");
		st.rerun();
	}
	if (cols[1].button("Discard"))
	{
		st.resetWidgets("customers-editor");
		st.rerun();
	}
}
