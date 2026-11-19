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

public import streamlitd.delta : St, QueryParams, UserInfo, RequestContext;
public import streamlitd.session : AppSession, AppFn, Layout, PageConfig, RunStatus;
public import streamlitd.state : SessionState;
public import streamlitd.errors;
public import streamlitd.dataframe : DataFrame, Row, ColumnType;
public import streamlitd.columnconfig : ColumnConfig;
public import streamlitd.dataelements : TableSelection, TableCell;
public import streamlitd.calendar : GridRow, GridItem, GridEvent;
public import streamlitd.elements : ProgressBar, Spinner, TimelineItem, LegendItem, FeedItem;
public import streamlitd.widgets : TreeNode, DateRange;
public import streamlitd.media : UploadedFile;
public import streamlitd.pages : Page;
public import streamlitd.cache : cacheData, cacheResource, cacheClear, clearAllCaches;
public import streamlitd.blocking : blocking;
public import streamlitd.text : escapeMarkdown;
public import streamlitd.server : serve, runMain, ServerOptions, RoutesFn, apiUser, requireUser, requireRole;
// accounts: sign-up, user store, roles (see docs/authentication.md)
public import streamlitd.accounts : Accounts, AccountError, StoredUser, Invite, UserStore, MemoryUserStore,
	JsonFileUserStore, useUserStore, accounts, Registration, AccountSettings, userToJson, userFromJson;
// HTTP API building blocks (FastAPI-like endpoints next to the app; see docs/api-endpoints.md)
public import vibe.http.router : URLRouter;
public import vibe.http.server : HTTPServerRequest, HTTPServerResponse;
public import vibe.http.common : HTTPStatusException, HTTPMethod;
public import vibe.http.status : HTTPStatus;
public import vibe.web.rest : registerRestInterface, RestInterfaceSettings, RestInterfaceClient;
public import streamlitd.openapi : registerApi, ApiDoc, apiDoc, apiDocsCompiledIn;
// route attributes (@path, @method, @before, @queryParam, ...) come from `import vibe.web.rest;`
public import streamlitd.secrets : Secrets, secrets;
public import streamlitd.components : Component, declareComponent;
public import streamlitd.fragments : StatusContainer, FragmentRef, refreshFragments;
public import streamlitd.theme : Theme, ThemeTokens, DesignStyle, colorSchemeNames, designNames, themePresetNames,
	fontSans, fontSerif, fontMono, fontRounded, registerColorScheme, registerDesign;
// app-defined native elements and widgets (see docs/extending.md)
public import streamlitd.extensions : registerElement, elementNames;
public import streamlitd.testing : AppTest;
public import vibe.data.json : Json, parseJsonString;
public import std.datetime : Date, TimeOfDay;

/// Generates `main()` that serves `app` (a `void app(St st)` function).
/// `StreamlitMain!(app, routes)` also registers your own HTTP routes with a
/// `void routes(URLRouter r)` function, e.g. a JSON API (see docs/api-endpoints.md).
mixin template StreamlitMain(alias app, routes...)
{
	static assert(routes.length <= 1, "StreamlitMain!(app, routes) takes at most one routes function");
	int main(string[] args)
	{
		import std.functional : toDelegate;
		import streamlitd.server : runMain;
		static if (routes.length == 0)
			return runMain(toDelegate(&app), args);
		else
			return runMain(toDelegate(&app), args, toDelegate(&routes[0]));
	}
}
