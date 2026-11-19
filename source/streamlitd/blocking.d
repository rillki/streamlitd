/// Running blocking calls without stalling other sessions.
///
/// App scripts run as vibe.d tasks on worker threads; several sessions share one thread. A call
/// that blocks the thread (a non-vibe database driver such as ODBC, `std.net.curl`,
/// `Thread.sleep`, a long CPU loop) also stops the other sessions on that thread. `blocking(...)`
/// runs such a call on a thread of its own while the calling task yields, so the others go on.
module streamlitd.blocking;

import core.atomic : atomicLoad, atomicStore;
import std.traits : ReturnType;

/// Run `fn` on a separate thread and wait for it without blocking the current vibe.d thread.
/// Exceptions thrown by `fn` are rethrown here. Outside a vibe.d task (tests, `main`) it simply
/// calls `fn`.
/// ---
/// auto rows = blocking(() => odbcQuery("SELECT ..."));
/// ---
auto blocking(F)(F fn)
	if (is(typeof(fn())))
{
	import core.thread : Thread;
	import vibe.core.sync : createSharedManualEvent;
	import vibe.core.task : Task;
	alias T = typeof(fn());
	if (Task.getThis() == Task.init)
		return fn();
	auto ev = createSharedManualEvent();
	shared bool done;
	Throwable err;
	static if (!is(T == void))
		T result;
	auto count = ev.emitCount;
	auto t = new Thread({
		try
		{
			static if (is(T == void))
				fn();
			else
				result = fn();
		}
		catch (Throwable e)
			err = e;
		atomicStore(done, true);
		ev.emit();
	});
	t.isDaemon = true;
	t.start();
	while (!atomicLoad(done))
		count = ev.wait(count);
	if (err !is null)
		throw err;
	static if (!is(T == void))
		return result;
}

unittest
{
	// outside a task it just calls the function; exceptions pass through
	assert(blocking(() => 21 * 2) == 42);
	int n;
	blocking({ n = 7; });
	assert(n == 7);
	import std.exception : assertThrown;
	assertThrown(blocking(() { throw new Exception("x"); }));
}
