/// An app's own extensions: color schemes, a design style and native widgets/elements.
///
/// - the color scheme "acme" and the element "badge" are registered here, in D;
/// - the color scheme "dusk", the design "neon" and the widget "rating" come from
///   .streamlitd/config.toml (with the browser files in ui/).
///
/// Open the settings menu (top right) to switch between them. See docs/extending.md.
import streamlitd;
import std.conv : to;

shared static this()
{
	ThemeTokens acme;
	acme.primaryColor = "#0055aa";
	acme.chartColors = ["#0055aa", "#ff8800", "#22aa55", "#aa3377", "#33bbee"];
	ThemeTokens acmeDark;
	acmeDark.primaryColor = "#4d9fff";
	acmeDark.backgroundColor = "#0b1220";
	acmeDark.secondaryBackgroundColor = "#16213a";
	registerColorScheme("acme", "Acme Corp", both: acme, dark: acmeDark);

	// the browser files are compiled into the binary (dub.json: "stringImportPaths": ["ui"])
	registerElement("badge", js: import("badge.js"), css: import("badge.css"));
	// a widget whose script has a syntax error (?demo=broken): it shows an error box, and since
	// every element has its own script file, the other elements keep working
	registerElement("ghost", js: "StreamlitD.registerElement(\"ghost\", { render( });");
}

void app(St st)
{
	st.title("Your own widgets and themes");
	st.customElement("badge", Json(["text": Json("custom element"), "tone": Json("primary")]));
	st.markdown("The **acme** and **dusk** color schemes and the **neon** design were added by this app. " ~
		"Pick them in the settings menu (⚙, top right).");

	st.header("A custom widget");
	auto stars = st.customWidget!int("rating", "How do you like it?", 3, Json(["max": Json(5)]), key: "stars",
		help: "A native widget drawn by ui/rating.js");
	st.write("You picked", stars, "of 5 stars.");
	if (stars >= 4)
		st.customElement("badge", Json(["text": Json("thank you!"), "tone": Json("muted")]));

	st.header("In a form");
	auto f = st.form("review");
	auto inForm = f.customWidget!int("rating", "Rate the form", 0, Json(["max": Json(10)]));
	auto comment = f.textInput("Comment");
	if (f.formSubmitButton("Submit"))
		st.success("Submitted " ~ inForm.to!string ~ "/10" ~ (comment.length ? ": " ~ comment : ""));

	st.header("Charts follow the scheme");
	st.barChart(DataFrame.fromRows(["team", "score"],
		[[Json("A"), Json(3)], [Json("B"), Json(5)], [Json("C"), Json(2)]]), x: "team", y: ["score"]);

	if (st.queryParams.get("demo") == "broken")
		st.customWidget!int("ghost", "Ghost", 0);
}

mixin StreamlitMain!app;
