/// Multipage app with navigation, chat and query params.
import streamlitd;
import std.conv : to;
import std.uni : toUpper;

void home(St st)
{
	st.title("🏠 Home");
	st.write("This is a multipage **streamlitd** app. Use the sidebar to navigate.");
	st.pageLink("chat", "Go to the chat page", "💬");
	if (st.button("Switch to settings"))
		st.switchPage("Settings");
}

void chat(St st)
{
	st.title("💬 Echo bot");
	auto history = st.session.get!(string[][])("history");
	foreach (m; history)
		st.chatMessage(m[0]).markdown(m[1]);
	if (auto prompt = st.chatInput("Say something"))
	{
		st.chatMessage("user").markdown(prompt);
		auto reply = "You said: **" ~ prompt.toUpper ~ "**";
		st.chatMessage("assistant").markdown(reply);
		history ~= ["user", prompt];
		history ~= ["assistant", reply];
		st.session["history"] = history;
	}
	if (history.length && st.sidebar.button("Clear chat"))
	{
		st.session.remove("history");
		st.rerun();
	}
}

void settings(St st)
{
	st.title("⚙️ Settings");
	auto q = st.queryParams;
	auto theme = st.radio("Theme", ["light", "dark"], q.get("theme", "light") == "dark" ? 1 : 0);
	if (q["theme"] != theme)
		q["theme"] = theme;
	st.write("Query param theme =", q.get("theme", "(none)"));
}

void app(St st)
{
	st.setPageConfig(title: "Multipage demo", icon: "📚");
	auto page = st.navigation([
		Page(&home, "Home", "🏠"),
		Page(&chat, "Chat", "💬"),
		Page(&settings, "Settings", "⚙️"),
	]);
	page.run(st);
}

mixin StreamlitMain!app;
