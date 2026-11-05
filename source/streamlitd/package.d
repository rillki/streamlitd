/// streamlitd — build reactive data apps in D, the Streamlit way.
///
/// ---
/// import streamlitd;
///
/// void app(St st)
/// {
///     st.title("Hello");
///     auto name = st.textInput("Your name");
///     if (st.button("Greet"))
///         st.success("Hi " ~ name);
/// }
///
/// mixin StreamlitMain!app;
/// ---
module streamlitd;

public import streamlitd.delta : St, QueryParams, UserInfo;
public import streamlitd.session : AppSession, AppFn, Layout, PageConfig, RunStatus;
public import streamlitd.state : SessionState;
public import streamlitd.errors;
public import streamlitd.dataframe : DataFrame, Row, ColumnType;
public import streamlitd.elements : ProgressBar, Spinner;
public import streamlitd.media : UploadedFile;
public import streamlitd.pages : Page;
public import streamlitd.cache : cacheData, cacheResource, cacheClear, clearAllCaches;
public import streamlitd.server : serve, runMain, ServerOptions;
public import streamlitd.secrets : Secrets, secrets;
public import streamlitd.components : Component, declareComponent;
public import streamlitd.fragments : StatusContainer;
public import streamlitd.theme : Theme, ThemeTokens, themePresetNames, fontSans, fontSerif, fontMono, fontRounded;
public import streamlitd.testing : AppTest;
public import vibe.data.json : Json, parseJsonString;
public import std.datetime : Date, TimeOfDay;

/// Generates `main()` that serves `app` (a `void app(St st)` function).
mixin template StreamlitMain(alias app)
{
	int main(string[] args)
	{
		import std.functional : toDelegate;
		import streamlitd.server : runMain;
		return runMain(toDelegate(&app), args);
	}
}
