/// The app driven by tests/load/load.mjs: per-session values (cross-talk check), a cached slow
/// computation (computed once for everybody), a slow call run with `blocking` (must not hold up
/// other sessions), and a fragment refreshed for all sessions by `refreshFragments`.
import streamlitd;
import core.atomic : atomicLoad, atomicOp;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;

shared int g_computed, g_pushes;

int slowSquare(int x)
{
	atomicOp!"+="(g_computed, 1);
	blocking({ Thread.sleep(400.msecs); }); // a slow query
	return x * x;
}

void app(St st)
{
	auto name = st.textInput("Name", "", key: "name");
	if (st.button("Echo"))
		st.text("echo:" ~ name);
	if (st.button("Cached"))
		st.text("cached:" ~ cacheData!slowSquare(7).to!string ~ " computed:" ~ atomicLoad(g_computed).to!string);
	if (st.button("Slow"))
	{
		blocking({ Thread.sleep(1500.msecs); }); // e.g. a blocking database driver
		st.text("slow:done");
	}
	st.fragment((St f) { f.text("pushed:" ~ atomicLoad(g_pushes).to!string); }, refreshOn: "load");
	if (st.button("Push"))
	{
		atomicOp!"+="(g_pushes, 1);
		refreshFragments("load");
	}
}

mixin StreamlitMain!app;
