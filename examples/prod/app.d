/// Production features: config.toml, secrets, base URL path, worker threads.
import streamlitd;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import core.time : msecs;

void app(St st)
{
	st.title("Production setup");
	st.write("Served under `/app/` (baseUrlPath from `.streamlitd/config.toml`).");
	st.write("Secret greeting:", st.secrets.get!string("greeting"));
	st.write("DB user:", st.secrets["db"]["user"].get!string);

	auto c = st.columns(2);
	if (c[0].button("Busy CPU 3s"))
	{
		// pure CPU work with no st.* calls: only blocks this session's worker thread
		auto sw = StopWatch(AutoStart.yes);
		ulong x;
		while (sw.peek < 3000.msecs)
			x = x * 6364136223846793005UL + 1;
		st.success("busy done " ~ (x % 10).to!string);
	}
	st.session.setDefault("pings", 0);
	if (c[1].button("Ping"))
		st.session["pings"] = st.session.get!int("pings") + 1;
	st.text("pings=" ~ st.session.get!int("pings").to!string);

	st.image(cast(const(ubyte)[]) `<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="#00a86b"/></svg>`,
		caption: "media under base path");
}

mixin StreamlitMain!app;
