/// Widget, layout, form and session-state gallery.
import streamlitd;
import std.conv : to;
import std.array : join;
import std.format : format;

void app(St st)
{
	st.setPageConfig(title: "Widgets", icon: "🎛️", layout: Layout.wide);
	st.title("Widget gallery");
	st.caption("Every interaction reruns this D function from top to bottom.");

	auto tabs = st.tabs(["Inputs", "Layout", "Forms", "Status", "More"]);
	more(tabs[4]);

	// ---------------------------------------------------------------- inputs
	with (tabs[0])
	{
		auto c = columns(2);
		with (c[0])
		{
			auto name = textInput("Name", "Ann", placeholder: "Type a name");
			auto pwd = textInput("Password", type: "password");
			auto bio = textArea("Bio", "Hello!", height: 100);
			auto age = numberInput("Age", 30, minValue: 0, maxValue: 120);
			auto weight = numberInput("Weight (kg)", 70.5, step: 0.5);
			auto level = slider("Level", 0, 100, 25);
			auto rng = slider("Price range", 0.0, 100.0, [20.0, 80.0], step: 1.0);
			auto size = selectSlider("T-shirt size", ["XS", "S", "M", "L", "XL"], 2);
			text(format("name=%s pwdlen=%d age=%d weight=%.1f level=%d range=%.0f-%.0f size=%s bio=%s",
				name, pwd.length, age, weight, level, rng[0], rng[1], size, bio));
		}
		with (c[1])
		{
			auto agree = checkbox("I agree");
			auto dark = toggle("Dark mode");
			auto color = radio("Favourite color", ["Red", "Green", "Blue"], 1, horizontal: true);
			auto city = selectbox("City", ["Almaty", "Astana", "Shymkent"]);
			auto langs = multiselect("Languages", ["D", "Python", "Rust", "Go"], ["D"]);
			auto day = dateInput("Day", Date(2024, 5, 17));
			auto time = timeInput("Time", TimeOfDay(9, 30));
			auto pick = colorPicker("Pick a color", "#ff4b4b");
			text(format("agree=%s dark=%s color=%s city=%s langs=%s day=%s time=%02d:%02d pick=%s",
				agree, dark, color, city, langs.join(","), day.toISOExtString, time.hour, time.minute, pick));
		}

		subheader("Session state & callbacks");
		st.session.setDefault("count", 0);
		auto bc = columns([1, 1, 3]);
		bc[0].button("➕ Increment", key: "inc", onClick: () { st.session["count"] = st.session.get!int("count") + 1; });
		if (bc[1].button("Reset", key: "reset"))
			st.session["count"] = 0;
		bc[2].metric("Counter", st.session.get!int("count"), st.session.get!int("count") > 0 ? "+1" : null);

		auto keyed = textInput("Keyed input (st.session[\"note\"])", key: "note");
		if (button("Fill note"))
		{
			st.session["note"] = "filled from code";
			rerun();
		}
		write("note is:", keyed.length ? keyed : "(empty)");
	}

	// ---------------------------------------------------------------- layout
	with (tabs[1])
	{
		auto cols = columns(3, border: true);
		cols[0].metric("Temperature", "70 °F", "1.2 °F");
		cols[1].metric("Wind", "9 mph", "-8%");
		cols[2].metric("Humidity", "86%", "4%", deltaColor: "inverse");

		with (expander("Click to expand"))
		{
			write("Hidden content inside an **expander**.");
			code("void main() { writeln(\"hi\"); }", "d");
		}
		with (container(border: true))
		{
			text("A bordered container");
			jsonOf(["answer": 42]);
		}
		auto ph = empty();
		ph.info("This placeholder was replaced...");
		ph.success("...by a newer element (st.empty).");
		with (popover("Open popover"))
		{
			write("Popover content");
			settingsButton(); // the appearance panel opens from here too
		}
	}

	// ---------------------------------------------------------------- forms
	with (tabs[2])
	{
		auto f = form("signup", clearOnSubmit: true);
		auto email = f.textInput("Email");
		auto plan = f.selectbox("Plan", ["Free", "Pro", "Enterprise"]);
		auto qty = f.slider("Seats", 1, 50, 5);
		auto sub = f.formSubmitButton("Sign up", type: "primary");
		if (sub)
			success(format("Signed up %s for %s with %d seats", email, plan, qty));
		else
			caption("Values are sent only when the form is submitted.");
	}

	// ---------------------------------------------------------------- status
	with (tabs[3])
	{
		success("Success message");
		info("Info message", icon: "ℹ️");
		warning("Warning message");
		error("Error message");
		if (button("Toast me"))
			toast("Hello from a toast!", icon: "🍞");
		if (button("Run long task"))
		{
			auto bar = progress(0, "Working...");
			{
				auto sp = spinner("Crunching numbers...");
				foreach (i; 1 .. 11)
				{
					sleep(0.05);
					bar.progress(i * 10, "Step " ~ i.to!string ~ "/10");
				}
			}
			success("Long task done");
		}
		if (button("Raise exception"))
			throw new Exception("Something went wrong in the app");
	}
}

/// streamlitd's extra elements: cards, stepper, skeleton, timeline, avatars, details, tags,
/// tree select, date range and copy button.
void more(St st)
{
	st.subheader("Cards");
	auto cols = st.columns(3);
	foreach (i, name; ["Revenue", "Orders", "Customers"])
	{
		auto c = cols[i].card(name, "Last 30 days", icon: ["💰", "📦", "👥"][i]);
		c.metric(name, ["$48.2k", "1,204", "312"][i], ["+12%", "+3%", "-1%"][i]);
		c.button("Open " ~ name, key: "card-" ~ name);
	}

	st.subheader("Stepper");
	auto steps = ["Account", "Address", "Payment", "Confirm"];
	auto step = st.session.get!int("wizard", 0);
	st.stepper(steps, step);
	auto nav = st.columns(6);
	if (nav[0].button("Back", key: "wizard-back", disabled: step == 0))
	{
		st.session["wizard"] = step - 1;
		st.rerun();
	}
	if (nav[1].button(step + 1 < steps.length ? "Next" : "Finish", key: "wizard-next", type: "primary",
		disabled: step >= steps.length))
	{
		st.session["wizard"] = step + 1;
		st.rerun();
	}

	st.subheader("Loading placeholder");
	st.skeleton(3);

	st.subheader("Timeline");
	st.timeline([
		TimelineItem("Order placed", "09:12", "Order **#1042**, 3 items", null, null),
		TimelineItem("Payment received", "09:14", null, "💳", "success"),
		TimelineItem("Address check", "09:20", "The street name was corrected.", null, "warning"),
		TimelineItem("Shipped", "11:05", null, "🚚", "info"),
	]);

	st.subheader("People and records");
	auto who = st.columns([1, 1, 1, 6]);
	who[0].avatar("Ann Lee");
	who[1].avatar("Bob Stone", size: "large");
	who[2].avatar("Carla Diaz", size: "small");
	st.details([["Customer", "ACME Corp"], ["Contact", "Ann Lee"], ["Since", "2019"], ["Status", "**Active**"]]);

	st.subheader("More inputs");
	auto tags = st.tagsInput("Tags", ["d", "dashboard"], ["streamlit", "vibe.d", "charts", "reports"], maxTags: 5, key: "tags");
	auto regions = st.treeSelect("Regions", [
		TreeNode("eu", "Europe", [TreeNode("de", "Germany"), TreeNode("fr", "France"), TreeNode("es", "Spain")]),
		TreeNode("am", "Americas", [TreeNode("us", "United States"), TreeNode("br", "Brazil")]),
		TreeNode("as", "Asia", [TreeNode("jp", "Japan")]),
	], ["de"], key: "regions");
	auto period = st.dateRangeInput("Period", DateRange(Date(2026, 1, 1), Date(2026, 1, 31)), key: "period");
	st.write("Tags:", tags.join(", "), "· Regions:", regions.join(", "), "· Period:",
		period.start.toISOExtString ~ " – " ~ period.end.toISOExtString);
	st.copyButton("https://example.com/report?period=" ~ period.start.toISOExtString, "Copy report link");
}

mixin StreamlitMain!app;
