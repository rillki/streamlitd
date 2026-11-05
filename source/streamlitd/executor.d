/// Running app scripts on vibe.d worker threads, so CPU-heavy scripts do not block
/// the event loop (and other sessions). Outgoing messages are queued in an outbox
/// that the session's WebSocket task drains on the event-loop thread.
module streamlitd.executor;

import core.atomic;
import core.sync.mutex : Mutex;
import vibe.core.core : runWorkerTaskH, setupWorkerThreads;
import vibe.core.sync : ManualEvent, createSharedManualEvent;
import vibe.data.json;

import streamlitd.session;

private __gshared AppSession[string] g_jobs;
private __gshared Mutex g_jobsLock;

shared static this()
{
	g_jobsLock = new Mutex;
}

/// Start `n` worker threads (0 = one per CPU core). Call once before serving.
void startScriptWorkers(uint n)
{
	setupWorkerThreads(n);
}

/// Run one `sess.runPending()` on a worker thread and wait (yielding the calling fiber) until it is done.
void runOnceInWorker(AppSession sess)
{
	synchronized (g_jobsLock)
		g_jobs[sess.id] = sess;
	auto t = runWorkerTaskH(&workerEntry, sess.id);
	t.join();
}

private void workerEntry(string sid) nothrow
{
	try
	{
		AppSession s;
		synchronized (g_jobsLock)
		{
			s = g_jobs.get(sid, null);
			g_jobs.remove(sid);
		}
		if (s !is null)
			s.runPending();
	}
	catch (Throwable t)
	{
		try
		{
			import std.stdio : stderr;
			stderr.writeln("streamlitd: script worker failed: ", t.msg);
		}
		catch (Exception) {}
	}
}

/// Thread-safe transport: messages are serialized and queued; `drain()` is called by the
/// WebSocket task on the event-loop thread whenever `event` fires.
final class OutboxTransport : Transport
{
	private Mutex m;
	private string[] items;
	private bool closed_;
	shared(ManualEvent) event;

	this()
	{
		m = new Mutex;
		event = createSharedManualEvent();
	}

	void send(Json msg)
	{
		auto s = msg.toString();
		synchronized (m)
		{
			if (closed_)
				return;
			items ~= s;
		}
		event.emit();
	}

	/// Take all queued messages.
	string[] drain()
	{
		synchronized (m)
		{
			auto r = items;
			items = null;
			return r;
		}
	}

	/// Stop accepting messages.
	void close()
	{
		synchronized (m)
			closed_ = true;
		event.emit();
	}

	bool isClosed()
	{
		synchronized (m)
			return closed_;
	}
}

unittest
{
	auto t = new OutboxTransport;
	t.send(Json(["a": Json(1)]));
	t.send(Json(2));
	assert(t.drain() == [`{"a":1}`, "2"]);
	assert(t.drain().length == 0);
	t.close();
	t.send(Json(3));
	assert(t.drain().length == 0);
}
