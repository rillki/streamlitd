/// Images, audio/video, file upload and download.
module streamlitd.mediaelements;

import vibe.data.json;
import streamlitd.media;
import streamlitd.util;

package Json uploadsToJson(UploadedFile[] files)
{
	auto a = Json.emptyArray;
	foreach (f; files)
		a ~= jo("fileId", f.fileId, "name", f.name, "type", f.type, "size", f.size);
	return a;
}

package UploadedFile[] uploadsFromJson(string sessionId, Json j)
{
	UploadedFile[] r;
	if (j.type != Json.Type.array)
		return r;
	foreach (e; j)
		if (auto f = MediaManager.getUpload(sessionId, e["fileId"].opt!string(null)))
			r ~= f;
	return r;
}

/// Media elements mixed into `St`.
mixin template MediaElements()
{

	private string registerMedia(const(ubyte)[] data, string mime, string fileName = null)
	{
		auto url = MediaManager.add(sess.id, data, mime, fileName);
		sess.useMedia(url["_media/".length .. $], fragmentId);
		return url;
	}

	/// `st.image` from encoded bytes (PNG, JPEG, GIF, WebP, SVG).
	void image(const(ubyte)[] data, string caption = null, int width = 0, string mime = null,
		bool useContainerWidth = false)
	{
		auto url = registerMedia(data, mime.length ? mime : mimeFromBytes(data));
		emit(jo("kind", "image", "src", url, "caption", caption, "width", width, "fullWidth", useContainerWidth));
	}

	/// `st.image` from a file path or an http(s)/data URL.
	void image(string pathOrUrl, string caption = null, int width = 0, bool useContainerWidth = false)
	{
		auto src = mediaSrc(pathOrUrl);
		emit(jo("kind", "image", "src", src, "caption", caption, "width", width, "fullWidth", useContainerWidth));
	}

	/// The page favicon: an emoji, an http(s)/data URL, or a local image file (served from the app).
	/// Same as `st.setPageConfig(icon: ...)`.
	void setFavicon(string emojiUrlOrPath)
	{
		sess.send(jo("type", "page_config", "icon", faviconSrc(emojiUrlOrPath)));
	}

	/// ditto, from image bytes (png, svg, ico, ...).
	void setFavicon(const(ubyte)[] data, string mime = null)
	{
		sess.send(jo("type", "page_config", "icon", registerMedia(data, mime.length ? mime : mimeFromBytes(data))));
	}

	/// Resolve a page icon: local image files become app-served media URLs; emoji and URLs pass through.
	package string faviconSrc(string icon)
	{
		import std.file : exists, isFile;
		if (icon is null || icon.length == 0 || icon.startsWith("http://") || icon.startsWith("https://") || icon.startsWith("data:"))
			return icon;
		bool file; // an existing file (absolute or relative path) is served by the app
		try
			file = icon.length < 4096 && exists(icon) && isFile(icon);
		catch (Exception) {}
		return file ? mediaSrc(icon) : icon; // otherwise an emoji or a server-relative URL
	}

	/// `st.logo`: an image shown at the top of the sidebar, or in the top-left corner of the page
	/// while the sidebar is hidden (no sidebar content) or collapsed.
	void logo(string pathOrUrl, string link = null, string size = "medium")
	{
		sess.send(jo("type", "logo", "src", mediaSrc(pathOrUrl), "link", link, "size", size));
	}

	/// ditto, from image bytes.
	void logo(const(ubyte)[] data, string link = null, string size = "medium", string mime = null)
	{
		auto src = registerMedia(data, mime.length ? mime : mimeFromBytes(data));
		sess.send(jo("type", "logo", "src", src, "link", link, "size", size));
	}

	/// `st.audio` from bytes or a path/URL.
	void audio(const(ubyte)[] data, string mime = "audio/wav")
	{
		emit(jo("kind", "audio", "src", registerMedia(data, mime)));
	}

	/// `st.video` from bytes.
	void video(const(ubyte)[] data, string mime = "video/mp4")
	{
		emit(jo("kind", "video", "src", registerMedia(data, mime)));
	}

	private string mediaSrc(string pathOrUrl)
	{
		if (pathOrUrl.startsWith("http://") || pathOrUrl.startsWith("https://") || pathOrUrl.startsWith("data:"))
			return pathOrUrl;
		auto data = cast(const(ubyte)[]) read(pathOrUrl);
		return registerMedia(data, mimeFromName(pathOrUrl));
	}

	/// `st.audio` from a file path or an http(s)/data URL.
	void audio(string pathOrUrl) { emit(jo("kind", "audio", "src", mediaSrc(pathOrUrl))); }

	/// `st.video` from a file path or an http(s)/data URL.
	void video(string pathOrUrl) { emit(jo("kind", "video", "src", mediaSrc(pathOrUrl))); }

	/// `st.download_button` — returns true on the run triggered by the click.
	bool downloadButton(string label, const(ubyte)[] data, string fileName, string mime = "application/octet-stream",
		string key = null, string help = null, void delegate() onClick = null, bool disabled = false,
		string type = "secondary", bool useContainerWidth = false, string icon = null)
	{
		auto url = registerMedia(data, mime, fileName);
		auto id = widgetId("download_button", key, label, fileName);
		auto p = jo("label", label, "help", help, "disabled", disabled, "type", type, "fullWidth", useContainerWidth,
			"url", url, "fileName", fileName, "icon", icon);
		return widget!bool("download_button", id, key, false, (bool v) => Json(v), (Json j) => true, onClick, p, true);
	}

	/// ditto, with the file built only when it is clicked (not on every run), e.g. an Excel export
	/// (streamlitd only). `build` runs on its own thread, so a slow export does not hold up other
	/// sessions. The link works while the button is on the page. No rerun happens on click.
	void downloadButton(string label, const(ubyte)[] delegate() build, string fileName,
		string mime = "application/octet-stream", string key = null, string help = null, bool disabled = false,
		string type = "secondary", bool useContainerWidth = false, string icon = null)
	{
		auto id = widgetId("download_button", key, label, fileName, "lazy");
		if (id in sess.seenIds)
			throw new DuplicateWidgetID("There are multiple download buttons with the same id (`" ~ id ~
				"`). Pass a unique `key` argument to each of them.");
		sess.seenIds[id] = true;
		auto url = sess.registerLazyDownload(id, AppSession.LazyDownload(build, fileName, mime));
		emit(jo("kind", "download_button", "label", label, "help", help, "disabled", disabled, "type", type,
			"fullWidth", useContainerWidth, "url", url, "fileName", fileName, "icon", icon, "lazy", true));
	}

	/// ditto, text built on click.
	void downloadButton(string label, string delegate() build, string fileName, string mime = "text/plain",
		string key = null, string help = null, bool disabled = false, string type = "secondary",
		bool useContainerWidth = false, string icon = null)
	{
		downloadButton(label, () => cast(const(ubyte)[]) build(), fileName, mime, key, help, disabled, type,
			useContainerWidth, icon);
	}

	/// ditto, text data.
	bool downloadButton(string label, string data, string fileName, string mime = "text/plain",
		string key = null, string help = null, void delegate() onClick = null, bool disabled = false,
		string type = "secondary", bool useContainerWidth = false, string icon = null)
	{
		return downloadButton(label, cast(const(ubyte)[]) data, fileName, mime, key, help, onClick, disabled, type,
			useContainerWidth, icon);
	}

	private UploadedFile[] uploaderImpl(string label, string[] type, bool multiple, string key, string help,
		void delegate() onChange, bool disabled, string labelVisibility)
	{
		auto id = widgetId("file_uploader", key, label, type.join(","), multiple ? "m" : "s");
		auto p = jo("label", label, "help", help, "disabled", disabled, "labelVisibility", labelVisibility,
			"accept", type, "multiple", multiple, "sessionId", sess.id);
		auto sid = sess.id;
		return widget!(UploadedFile[])("file_uploader", id, key, null, (UploadedFile[] v) => uploadsToJson(v),
			(Json j) => uploadsFromJson(sid, j), onChange, p);
	}

	/// `st.file_uploader` — returns the uploaded file or `null`.
	/// `type` lists accepted extensions, e.g. `["csv", "txt"]`.
	UploadedFile fileUploader(string label, string[] type = null, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		auto r = uploaderImpl(label, type, false, key, help, onChange, disabled, labelVisibility);
		return r.length ? r[0] : null;
	}

	/// `st.file_uploader(accept_multiple_files=True)`
	UploadedFile[] fileUploaderMulti(string label, string[] type = null, string key = null, string help = null,
		void delegate() onChange = null, bool disabled = false, string labelVisibility = "visible")
	{
		return uploaderImpl(label, type, true, key, help, onChange, disabled, labelVisibility);
	}
}
