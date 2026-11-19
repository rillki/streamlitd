/// Dashboard: KPI tiles with trends, tickets per day, recent activity, all updated live.
module helpdesk.pages.dashboard;

import std.algorithm : count, filter;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, SysTime, UTC, unixTimeToStdTime;
import streamlitd;
import helpdesk.store;
import helpdesk.ui;

void dashboard(St st)
{
	st.title("Dashboard");
	// everything below reruns when any agent changes a ticket (Store calls refreshFragments)
	st.fragment((St f) {
		auto s = store;
		auto ts = s.tickets;
		auto t0 = now;
		// tickets opened per day over the last week (oldest first)
		auto perDay = new double[7];
		perDay[] = 0; // doubles start as NaN in D
		foreach (t; ts)
		{
			auto daysAgo = (t0 - t.created) / 86_400;
			if (daysAgo >= 0 && daysAgo < 7)
				perDay[6 - daysAgo]++;
		}
		long open = ts.count!(t => t.isOpen);
		long overdue = ts.count!(t => t.overdue(t0));
		long solvedToday = ts.count!(t => t.status == "solved" && t0 - t.updated < 86_400);
		auto k = f.columns(3);
		k[0].metric("Open tickets", open, chartData: perDay, caption: "opened per day, last 7 days", border: true);
		k[1].metric("Overdue", overdue, delta: overdue ? "needs attention" : null, deltaColor: "inverse", border: true);
		k[2].metric("Solved today", solvedToday, border: true);

		auto byStatus = new double[statuses.length];
		byStatus[] = 0;
		foreach (t; ts)
			foreach (i, st_; statuses)
				if (t.status == st_)
					byStatus[i]++;
		f.subheader("Tickets by status");
		f.proportionBar(byStatus, statuses.dup, ["info", "warning", "success", "muted"], format: "%d");

		auto cols = f.columns([3.0, 2]);
		cols[0].subheader("Opened per day");
		string[] days;
		foreach (i; 0 .. 7)
			days ~= SysTime(unixTimeToStdTime(t0 - (6 - i) * 86_400), UTC()).toISOExtString[5 .. 10];
		cols[0].barChart(new DataFrame().addColumn("day", days).addColumn("tickets", perDay), x: "day", y: ["tickets"], height: 220);
		cols[1].subheader("Recent activity");
		FeedItem[] items;
		foreach (a; s.activity(6))
			items ~= FeedItem(a.what, null, ago(t0 - a.at) ~ " ago · " ~ a.who, a.type);
		cols[1].feed(items);
	}, refreshOn: topic);
}
