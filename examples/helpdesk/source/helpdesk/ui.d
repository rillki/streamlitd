/// Shared pieces of the helpdesk's pages: the ticket table's columns and colours, time formatting.
module helpdesk.ui;

import std.conv : to;
import std.format : format;
import streamlitd;
import helpdesk.store;

alias C = ColumnConfig;

/// "5 min", "3 h", "2 d".
string ago(long seconds)
{
	if (seconds < 3600) return format("%d min", seconds / 60);
	if (seconds < 86_400) return format("%d h", seconds / 3600);
	return format("%d d", seconds / 86_400);
}

/// The tickets as a frame for `st.dataframe`.
DataFrame ticketFrame(Ticket[] ts, Store s)
{
	auto t0 = now;
	Json[][] rows;
	foreach (t; ts)
		rows ~= [Json(t.id), Json("#" ~ idText(t.id)), Json(t.title), Json(s.customerName(t.customer)), Json(t.priority),
			Json(t.status), Json(t.assignee.length ? t.assignee : "—"), Json((t0 - t.created) / 3600.0),
			Json(t.isOpen ? t.slaUsed(t0) * 100 : 0.0)];
	return DataFrame.fromRows(["id", "ticket", "title", "customer", "priority", "status", "assignee", "age", "sla"], rows);
}

/// Columns of the ticket table.
ColumnConfig[string] ticketColumns()
{
	return [
		"id": C.hide(),
		"ticket": C.text("Ticket", pinned: true, width: "small"),
		"title": C.text("Title", width: "large"),
		"customer": C.text("Customer"),
		"priority": C.text("Priority", width: "small"),
		"status": C.text("Status", width: "small"),
		"assignee": C.text("Assignee", width: "small"),
		"age": C.number("Age", format: "%.0f h", help: "Hours since the ticket was opened"),
		"sla": C.progress("SLA used", min: 0, max: 100, format: "%d%%", help: "Share of the answer time used (open tickets)"),
	];
}

/// Colours of the ticket table: urgent and overdue stand out.
string ticketCellStyle(size_t row, string col, Json v)
{
	if (col == "priority" && v.get!string == "urgent") return "text:error bold";
	if (col == "priority" && v.get!string == "high") return "text:warning";
	if (col == "status")
		switch (v.get!string)
		{
			case "open": return "bg:info";
			case "pending": return "bg:warning";
			case "solved": return "bg:success";
			default: return "text:muted";
		}
	if (col == "sla" && v.get!double >= 100) return "bg:error";
	return null;
}

/// Usernames with the agent role: the users in secrets.toml and the accounts admins added on the
/// Users page (active ones). Without accounts (unit tests): the demo agents.
string[] agents(St st)
{
	import std.algorithm : canFind, sort, uniq;
	import std.array : array;
	auto acc = accounts(); // the account service (null without [auth])
	if (acc is null)
		return ["alice", "bob"];
	string[] r;
	foreach (string name, u; acc.configUsers)
		if (u.type == Json.Type.object && u["roles"].type == Json.Type.array
			&& u["roles"].get!(Json[]).canFind(Json("agent")))
			r ~= name;
	foreach (u; acc.store.list)
		if (!u.disabled && !u.pending && u.roles.canFind("agent"))
			r ~= u.username;
	return r.sort.uniq.array;
}

/// The signed-in user's account name ("guest" in tests without a login).
string me(St st)
{
	auto u = st.user;
	return u.isLoggedIn ? u.username : "guest";
}
