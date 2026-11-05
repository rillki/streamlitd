import streamlitd;
import std.conv : to;

void app(St st)
{
	st.setPageConfig(title: "Hello streamlitd", icon: "👋");
	st.title("Hello, streamlitd 👋");
	st.markdown("Unsafe links are neutralised: [click](javascript:alert(1))");
	st.markdown("Build data apps in **D** — the _Streamlit_ way. Supports :blue[colored] text too.");

	auto name = st.textInput("Your name", "World");
	auto times = st.slider("Times", 1, 10, 3);
	if (st.button("Greet", type: "primary"))
		st.success("Hello " ~ name ~ "! " ~ times.to!string ~ "x");

	st.session.setDefault("clicks", 0);
	if (st.button("Count clicks"))
		st.session["clicks"] = st.session.get!int("clicks") + 1;
	st.write("Clicks so far:", st.session.get!int("clicks"));

	with (st.sidebar)
	{
		header("Sidebar");
		auto mood = selectbox("Mood", ["😀 happy", "😐 neutral", "😢 sad"]);
		write("You feel", mood);
	}
}

mixin StreamlitMain!app;
