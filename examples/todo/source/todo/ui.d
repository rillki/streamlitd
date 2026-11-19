/// Formatting shared by the TODO pages.
module todo.ui;

import core.time : days;
import std.algorithm : map;
import std.array : join;
import std.datetime : Date;
import streamlitd;
import todo.store;

/// "today", "tomorrow", "in 3 days", "yesterday", "Dec 4".
string dueText(Date d, Date t)
{
	static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	auto n = (d - t).total!"days";
	if (n == 0) return "today";
	if (n == 1) return "tomorrow";
	if (n == -1) return "yesterday";
	if (n > 1 && n < 7) return "in " ~ n.to!string ~ " days";
	return months[d.month - 1] ~ " " ~ d.day.to!string;
}

/// The small line under a task: due date (red when overdue), priority, tags.
string metaLine(Task t, Date today)
{
	string[] parts;
	if (t.due.length)
	{
		auto s = "🗓️ " ~ dueText(t.dueDate, today);
		parts ~= t.overdue(today) ? ":red[" ~ s ~ "]" : s;
	}
	if (t.priority == "high")
		parts ~= ":red-badge[high]";
	else if (t.priority == "low")
		parts ~= ":gray-badge[low]";
	foreach (g; t.tags)
		if (auto c = cleanTag(g)) // only safe characters inside the badge's brackets
			parts ~= ":blue-badge[#" ~ c ~ "]";
	return parts.join(" ");
}

/// The signed-in user (tests without a login act as "guest").
string me(St st)
{
	auto u = st.user;
	return u.isLoggedIn ? u.username : "guest";
}

private import std.conv : to;
