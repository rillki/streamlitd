/// In-memory storage for files served to the browser (images, downloads)
/// and files uploaded by the browser (file_uploader).
module streamlitd.media;

import streamlitd.util;
import core.sync.mutex : Mutex;

/// A blob served at `/_media/<id>`.
final class MediaFile
{
	string id;
	immutable(ubyte)[] data;
	string mime;
	string fileName;     /// set for downloads
	bool[string] owners; /// session ids referencing this file
}

/// A file uploaded through `st.fileUploader`.
final class UploadedFile
{
	string fileId;
	string name;
	string type;
	immutable(ubyte)[] data;
	string sessionId;
	string widgetId;

	/// Size in bytes.
	size_t size() const { return data.length; }
	/// Content as text.
	string text() const { return cast(string) data; }
	/// Raw bytes.
	const(ubyte)[] bytes() const { return data; }
}

/// Global registry (single event-loop thread).
struct MediaManager
{
	__gshared MediaFile[string] files;
	__gshared UploadedFile[string] uploads;
	private __gshared Mutex mlock;

	shared static this() { mlock = new Mutex; }

	/// Register a blob for a session; returns its URL.
	static string add(string sessionId, const(ubyte)[] data, string mime, string fileName = null)
	{
		synchronized (mlock)
		{
			auto id = hashBytes(data, mime ~ "|" ~ fileName);
			auto f = files.get(id, null);
			if (f is null)
			{
				f = new MediaFile;
				f.id = id;
				f.data = data.idup;
				f.mime = mime;
				f.fileName = fileName;
				files[id] = f;
			}
			f.owners[sessionId] = true;
			return "_media/" ~ id;
		}
	}

	static MediaFile get(string id)
	{
		synchronized (mlock)
			return files.get(id, null);
	}

	/// Drop references of a session to every file not in `keep`.
	static void releaseExcept(string sessionId, const bool[string] keep)
	{
		synchronized (mlock)
		{
			string[] dead;
			foreach (id, f; files)
			{
				if (sessionId in f.owners && id !in keep)
				{
					f.owners.remove(sessionId);
					if (f.owners.length == 0)
						dead ~= id;
				}
			}
			foreach (id; dead)
				files.remove(id);
		}
	}

	static UploadedFile addUpload(string sessionId, string widgetId, string name, string type, immutable(ubyte)[] data)
	{
		synchronized (mlock)
		{
			auto u = new UploadedFile;
			u.fileId = randomId();
			u.name = name;
			u.type = type;
			u.data = data;
			u.sessionId = sessionId;
			u.widgetId = widgetId;
			uploads[u.fileId] = u;
			return u;
		}
	}

	static UploadedFile getUpload(string sessionId, string fileId)
	{
		synchronized (mlock)
		{
			auto u = uploads.get(fileId, null);
			if (u is null || u.sessionId != sessionId)
				return null;
			return u;
		}
	}

	/// Remove everything belonging to a session.
	static void releaseSession(string sessionId)
	{
		synchronized (mlock)
		{
			releaseExcept(sessionId, null);
			string[] dead;
			foreach (id, u; uploads)
				if (u.sessionId == sessionId)
					dead ~= id;
			foreach (id; dead)
				uploads.remove(id);
		}
	}
}

unittest
{
	auto url = MediaManager.add("s1", [1, 2, 3], "image/png");
	auto id = url[7 .. $];
	assert(MediaManager.get(id) !is null);
	MediaManager.releaseExcept("s1", null);
	assert(MediaManager.get(id) is null);
	auto u = MediaManager.addUpload("s1", "w", "a.txt", "text/plain", cast(immutable(ubyte)[]) "hi");
	assert(MediaManager.getUpload("s1", u.fileId).text == "hi");
	assert(MediaManager.getUpload("s2", u.fileId) is null);
	MediaManager.releaseSession("s1");
	assert(MediaManager.getUpload("s1", u.fileId) is null);
}
