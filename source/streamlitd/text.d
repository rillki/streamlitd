/// Helpers for showing text that users typed.
module streamlitd.text;

/// Escape `s` so Markdown shows it as typed: no formatting, links, images, colour directives
/// (`:red[...]`), math (`$...$`) or HTML. Use it whenever user input goes into `st.markdown`,
/// `st.write`, labels, captions, feeds and the like:
/// ---
/// st.markdown("**" ~ escapeMarkdown(ticket.title) ~ "**");
/// ---
string escapeMarkdown(string s) @safe pure
{
	import std.array : appender;
	auto r = appender!string;
	r.reserve(s.length + s.length / 4);
	foreach (char c; s)
		switch (c)
		{
			case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '~', '>', '=', '^':
				r ~= '\\';
				r ~= c;
				break;
			// these are applied to the rendered HTML (or before Markdown), where a backslash
			// doesn't help: entities show the character without the meaning
			case ':': r ~= "&#58;"; break;
			case '$': r ~= "&#36;"; break;
			case '<': r ~= "&lt;"; break;
			case '&': r ~= "&amp;"; break;
			default: r ~= c;
		}
	return r.data;
}

///
unittest
{
	assert(escapeMarkdown("a*b*") == `a\*b\*`);
	assert(escapeMarkdown("![x](http://e/p.png)") == `\!\[x\]\(http&#58;//e/p\.png\)`);
	assert(escapeMarkdown(":red[x] $1$ <b>") == "&#58;red\\[x\\] &#36;1&#36; &lt;b\\>");
	assert(escapeMarkdown("plain text") == "plain text");
}
