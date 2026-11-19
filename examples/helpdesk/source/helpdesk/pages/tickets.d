/// Tickets: filters, a table with selection, the selected ticket's details and actions, an edit
/// dialog with a nested confirmation, a comment form, an export built on click.
module helpdesk.pages.tickets;

import std.algorithm : canFind, filter, map;
import std.array : array, join;
import std.conv : to;
import std.functional : toDelegate;
import std.string : toLower, strip;
import streamlitd;
import helpdesk.store;
import helpdesk.ui;

void tickets(St st)
{
	st.title("Tickets");
	// a fragment: filters and actions rerun only this part, and other agents' changes appear live
	st.fragment((St f) { ticketsBody(st, f); }, refreshOn: topic, key: "tickets");
}

package(helpdesk) Ticket[] filtered(Ticket[] ts, Store s, string status, string[] prios, string assignee, string q)
{
	auto query = q.strip.toLower;
	return ts.filter!(t =>
		(status == "all" || (status == "active" ? t.isOpen : t.status == status)) &&
		(!prios.length || prios.canFind(t.priority)) &&
		(assignee == "anyone" || (assignee == "nobody" ? !t.assignee.length : t.assignee == assignee)) &&
		(!query.length || t.title.toLower.canFind(query) || s.customerName(t.customer).toLower.canFind(query)
			|| ("#" ~ idText(t.id)).canFind(query))).array;
}

private void ticketsBody(St st, St f)
{
	auto s = store;
	auto who = me(st);
	auto c = f.columns([2.6, 2, 1.4, 2]);
	auto status = c[0].segmentedControl("Status", ["active", "all", "solved", "closed"], 0, key: "t-status", required: true);
	auto prios = c[1].multiselect("Priority", priorities.dup, null, key: "t-prio", placeholder: "Any priority");
	auto assignee = c[2].selectbox("Assignee", ["anyone", "nobody"] ~ agents(st), key: "t-assignee");
	auto q = c[3].textInput("Search", key: "t-search", placeholder: "Title, customer or #id");

	auto list = filtered(s.tickets, s, status, prios, assignee, q);
	if (!list.length)
	{
		f.emptyState("No tickets match", "Change the filters above.", "🔍");
		return;
	}
	auto sel = f.dataframe(ticketFrame(list, s), hideIndex: true, onSelect: "rerun", rowKey: "id", key: "ticket-table",
		columnConfig: ticketColumns(), cellStyle: toDelegate(&ticketCellStyle), maxHeight: 360,
		totals: ["ticket": "Total", "title": "count", "age": "mean"]);
	// safe: titles are typed by people; a spreadsheet must not run "=..." in them as a formula
	f.downloadButton("Export CSV", () => ticketFrame(list, s).select("ticket", "title", "customer", "priority", "status",
		"assignee").toCsv(',', true), "tickets.csv", "text/csv", icon: "⬇️");

	if (!sel.keys.length)
	{
		f.caption("Select a ticket to see it here.");
		return;
	}
	auto t = s.ticket(sel.keys[0].get!int);
	if (!t.id)
		return;
	detail(st, f, s, t, who);
}

private void detail(St st, St f, Store s, Ticket t, string who)
{
	f.divider();
	// titles, names and comments are typed by people: shown as text, never as Markdown
	f.subheader("#" ~ idText(t.id) ~ " · " ~ escapeMarkdown(t.title));
	auto cols = f.columns([3.0, 2]);
	with (cols[0])
	{
		details([["Customer", escapeMarkdown(s.customerName(t.customer))], ["Priority", "**" ~ t.priority ~ "**"], ["Status", t.status],
			["Assignee", t.assignee.length ? t.assignee : "nobody"], ["Opened", ago(now - t.created) ~ " ago"],
			["Answer due", t.overdue(now) ? ":red[overdue by " ~ ago(now - t.due) ~ "]" : "in " ~ ago(t.due - now)]], inline: false);
		TimelineItem[] items = [TimelineItem("Opened", ago(now - t.created) ~ " ago", null, "📨")];
		foreach (cm; t.comments)
			items ~= TimelineItem(escapeMarkdown(cm.author), ago(now - cm.at) ~ " ago", escapeMarkdown(cm.text), "💬");
		timeline(items);
		auto fm = form("comment-" ~ t.id.to!string, clearOnSubmit: true);
		auto text = fm.textArea("Add a comment", key: "comment-text-" ~ t.id.to!string, height: 80, maxChars: maxComment);
		if (fm.formSubmitButton("Comment") && text.strip.length)
			s.update(t.id, who, "commented on **#" ~ idText(t.id) ~ "**", (ref Ticket x) { x.comments ~= Comment(who, text.strip, now); });
	}
	with (cols[1])
	{
		auto newStatus = selectbox("Change status", statuses.dup, statuses.dup.countUntilOr(t.status), key: "status-" ~ t.id.to!string);
		auto choices = ["nobody"] ~ agents(st);
		if (t.assignee.length && !choices.canFind(t.assignee))
			choices ~= t.assignee; // assigned to someone who is no longer an agent
		auto newAssignee = selectbox("Assign to", choices, choices.countUntilOr(t.assignee.length ? t.assignee : "nobody"),
			key: "assign-" ~ t.id.to!string);
		if (button("Save changes", key: "save-" ~ t.id.to!string, type: "primary"))
		{
			auto a = newAssignee == "nobody" ? "" : newAssignee;
			s.update(t.id, who, "set **#" ~ idText(t.id) ~ "** to " ~ newStatus ~ (a.length ? ", assigned to " ~ a : ""),
				(ref Ticket x) { x.status = newStatus; x.assignee = a; }, newStatus == "solved" ? "success" : "info");
			st.toast("Saved #" ~ idText(t.id));
		}
		if (button("Edit…", key: "edit-" ~ t.id.to!string))
			st.session["editing"] = t.id;
	}
	if (st.session.get!int("editing", 0) == t.id)
		editDialog(st, s, t, who);
}

private void editDialog(St st, Store s, Ticket t, string who)
{
	st.dialog("Edit #" ~ idText(t.id), (St d) {
		auto title = d.textInput("Title", t.title, maxChars: maxTitle, key: "edit-title");
		auto prio = d.segmentedControl("Priority", priorities.dup, priorities.dup.countUntilOr(t.priority), key: "edit-prio", required: true);
		auto cols = d.columns(2);
		if (cols[0].button("Save", type: "primary", key: "edit-save"))
		{
			if (!title.strip.length)
				d.error("The title must not be empty.");
			else
			{
				s.update(t.id, who, "edited **#" ~ idText(t.id) ~ "**", (ref Ticket x) { x.title = title.strip; x.priority = prio; });
				st.session["editing"] = 0;
				st.rerun();
			}
		}
		if (cols[1].button("Close ticket…", key: "edit-close"))
			st.session["confirm-close"] = true;
		// a dialog from a dialog: asks before closing the ticket
		if (st.session.get!bool("confirm-close", false))
			st.dialog("Close #" ~ idText(t.id) ~ "?", (St c) {
				c.write("Closed tickets cannot be reopened by the customer.");
				auto b = c.columns(2);
				if (b[0].button("Yes, close it", type: "primary", key: "confirm-yes"))
				{
					s.update(t.id, who, "closed **#" ~ idText(t.id) ~ "**", (ref Ticket x) { x.status = "closed"; }, "success");
					st.session["confirm-close"] = false;
					st.session["editing"] = 0;
					st.rerun();
				}
				if (b[1].button("Cancel", key: "confirm-no"))
				{
					st.session["confirm-close"] = false;
					st.rerun();
				}
			}, onDismiss: { st.session["confirm-close"] = false; });
		// × and Esc: forget that it was open, or the next rerun would open it again
	}, width: "small", key: "edit-dialog", onDismiss: { st.session["editing"] = 0; st.session["confirm-close"] = false; });
}

/// The index of `v` in `a`, or 0.
private ptrdiff_t countUntilOr(string[] a, string v)
{
	foreach (i, x; a)
		if (x == v)
			return i;
	return 0;
}
