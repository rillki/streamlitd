/// The open sessions, for `refreshFragments` (a module of its own: its static constructor must
/// not sit in the import cycle of streamlitd.session / streamlitd.delta).
module streamlitd.liveregistry;

import core.sync.mutex : Mutex;

private __gshared Object[] g_live;
private __gshared Mutex g_lock;
shared static this() { g_lock = new Mutex; }

package void addLive(Object s)
{
	synchronized (g_lock)
		g_live ~= s;
}

package void removeLive(Object s)
{
	import std.algorithm : countUntil, remove;
	synchronized (g_lock)
	{
		auto i = g_live.countUntil!(x => x is s);
		if (i >= 0)
			g_live = g_live.remove(i);
	}
}

/// A copy of the list of open sessions.
package Object[] liveSessions()
{
	synchronized (g_lock)
		return g_live.dup;
}
