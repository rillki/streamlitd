/// A CSV import in four steps: upload, match unknown supplier names, review the changes, done.
module planning.pages.imports;

import std.algorithm : canFind, countUntil, map, sort, uniq;
import std.array : array;
import std.conv : to, ConvException;
import std.string : strip, toLower;
import streamlitd;
import planning.store;
import planning.ui;

/// The sample file shipped with the example (data/sample-plan.csv).
enum sampleCsv = import("sample-plan.csv");

immutable steps = ["Upload", "Match suppliers", "Review", "Done"];
enum newSupplier = "+ New supplier";
enum maxImportRows = 10_000;

/// A row of the file, checked.
struct ImportRow
{
	string supplier;   /// as written in the file
	string brand;
	int month;
	double amount;
}

/// Parse and check the file: rows, or the problems found.
package(planning) ImportRow[] parseImport(string csv, out string[] problems)
{
	DataFrame df;
	try
		df = DataFrame.fromCsv(csv);
	catch (Exception e)
	{
		problems ~= "Not a CSV file: " ~ e.msg;
		return null;
	}
	foreach (c; ["supplier", "brand", "month", "amount"])
		if (!df.hasColumn(c))
			problems ~= "The column \"" ~ c ~ "\" is missing.";
	if (problems.length)
		return null;
	if (df.length > maxImportRows)
	{
		problems ~= "The file has " ~ df.length.to!string ~ " rows; at most " ~ maxImportRows.to!string ~ " are imported at once.";
		return null;
	}
	ImportRow[] r;
	foreach (i; 0 .. df.length)
	{
		auto line = "Line " ~ (i + 2).to!string ~ ": ";
		string str(string c) { auto v = df.cell(i, c); return v.type == Json.Type.string ? v.get!string.strip : v.toString; }
		double num(string c)
		{
			auto v = df.cell(i, c);
			if (v.type == Json.Type.int_) return v.get!long;
			if (v.type == Json.Type.float_) return v.get!double;
			return str(c).to!double;
		}
		try
		{
			auto m = num("month");
			if (!(m >= 1 && m <= 12 && m == cast(int) m)) // also NaN and 12.5
			{
				problems ~= line ~ "month must be a whole number from 1 to 12.";
				continue;
			}
			auto row = ImportRow(str("supplier"), str("brand"), cast(int) m, num("amount"));
			if (!row.supplier.length || !row.brand.length) problems ~= line ~ "supplier and brand are required.";
			else if (!validAmount(row.amount)) problems ~= line ~ "the amount must be between 0 and 1,000,000,000.";
			else if (row.supplier.length > maxName || row.brand.length > maxName) problems ~= line ~ "the name is too long.";
			else r ~= row;
		}
		catch (ConvException)
			problems ~= line ~ "month and amount must be numbers.";
	}
	return r;
}

/// The known supplier a file name probably means (case and suffixes like "Ltd" ignored), or null.
package(planning) string guessSupplier(string name, Supplier[] known)
{
	auto n = name.toLower;
	foreach (k; known)
		if (n == k.name.toLower)
			return k.name;
	foreach (k; known)
		if (n.canFind(k.name.toLower) || k.name.toLower.canFind(n))
			return k.name;
	return null;
}

/// One planned change of the import.
struct ImportChange
{
	string kind;     /// "added", "changed", "same", "skipped"
	string supplier; /// known name, or the new one
	string brand;
	int month;
	double before = 0;
	double after = 0;
	string note;
}

/// What the import would do, with `mapping` (file name → known name or `newSupplier`).
package(planning) ImportChange[] previewImport(ImportRow[] rows, string[string] mapping, Store s)
{
	ImportChange[] r;
	auto brands = s.brands;
	foreach (row; rows)
	{
		auto target = mapping.get(row.supplier, newSupplier);
		auto supName = target == newSupplier ? row.supplier : target;
		string supId;
		foreach (x; s.suppliers)
			if (x.name == supName)
				supId = x.id;
		auto at = supId.length ? brands.countUntil!(b => b.supplier == supId && b.name == row.brand) : -1;
		auto c = ImportChange("added", supName, row.brand, row.month, 0, row.amount);
		if (isClosed(row.month))
		{
			c.kind = "skipped";
			c.note = "closed month";
		}
		else if (at >= 0)
		{
			c.before = brands[at].plan[row.month - 1];
			c.kind = c.before == c.after ? "same" : "changed";
		}
		else
			c.note = target == newSupplier ? "new supplier" : "new brand";
		r ~= c;
	}
	return r;
}

void importPage(St st)
{
	st.title("Import a plan");
	auto step = st.session.setDefault!int("import-step", 0);
	st.stepper(steps.dup, step);
	final switch (step)
	{
		case 0: upload(st); break;
		case 1: match(st); break;
		case 2: review(st); break;
		case 3: done(st); break;
	}
}

private void go(St st, int step)
{
	st.session["import-step"] = step;
	st.rerun();
}

private void upload(St st)
{
	st.write("A CSV file with the columns `supplier`, `brand`, `month` (1–12) and `amount`. Rows for closed "
		~ "months are skipped.");
	auto file = st.fileUploader("Plan file", ["csv"], key: "import-file");
	auto c = st.columns([1.0, 1, 3]);
	string csv;
	if (file !is null)
		csv = cast(string) file.data.idup;
	if (c[0].button("Use the sample file"))
		csv = sampleCsv;
	c[1].downloadButton("Download the sample", sampleCsv, "sample-plan.csv", "text/csv");
	if (!csv.length)
		return;
	string[] problems;
	auto rows = parseImport(csv, problems);
	foreach (p; problems.length > 10 ? problems[0 .. 10] : problems)
		st.error(escapeMarkdown(p)); // problems quote the file
	if (problems.length > 10)
		st.error("… and " ~ (problems.length - 10).to!string ~ " more problems.");
	if (problems.length)
		return;
	st.session["import-csv"] = csv;
	st.session["import-name"] = file !is null ? file.name : "sample-plan.csv";
	go(st, 1);
}

private ImportRow[] rowsOf(St st)
{
	string[] problems;
	return parseImport(st.session.get!string("import-csv", ""), problems);
}

private void match(St st)
{
	auto s = store;
	auto rows = rowsOf(st);
	auto known = s.suppliers;
	auto names = rows.map!(r => r.supplier).array.sort.uniq.array;
	auto unknown = names.filter!(n => !known.canFind!(k => k.name == n)).array;
	st.write("**" ~ escapeMarkdown(st.session.get!string("import-name", "")) ~ "**: " ~ rows.length.to!string ~ " rows, "
		~ names.length.to!string ~ " suppliers.");
	if (!unknown.length)
		st.success("Every supplier name is known.");
	else
		st.info("Some names in the file differ from the suppliers here. Choose the supplier each one means.");
	auto options = known.map!(k => k.name).array ~ newSupplier;
	string[string] mapping;
	foreach (n; unknown)
	{
		auto guess = guessSupplier(n, known);
		auto idx = guess.length ? options.countUntil(guess) : options.length - 1;
		mapping[n] = st.selectbox("“" ~ escapeMarkdown(n) ~ "” is", options, idx, key: "map-" ~ n);
	}
	st.session["import-map"] = mapping;
	auto c = st.columns([1.0, 1, 5]);
	if (c[0].button("Back"))
		go(st, 0);
	if (c[1].button("Next", type: "primary"))
		go(st, 2);
}

private void review(St st)
{
	auto s = store;
	auto rows = rowsOf(st);
	auto mapping = st.session.get!(string[string])("import-map", null);
	auto changes = previewImport(rows, mapping, s);
	Json[][] t;
	foreach (c; changes)
		t ~= [Json(c.kind), Json(c.supplier), Json(c.brand), Json(monthNames[c.month - 1]), Json(c.before), Json(c.after),
			Json(c.note)];
	auto df = DataFrame.fromRows(["change", "supplier", "brand", "month", "before", "after", "note"], t);
	auto counts = ["added": 0, "changed": 0, "same": 0, "skipped": 0];
	foreach (c; changes)
		counts[c.kind]++;
	auto k = st.columns(4);
	k[0].metric("New", counts["added"]);
	k[1].metric("Changed", counts["changed"]);
	k[2].metric("Unchanged", counts["same"]);
	k[3].metric("Skipped", counts["skipped"]);
	st.dataframe(df, hideIndex: true, maxHeight: 360, columnConfig: [
		"change": C.text("Change", width: "small"),
		"before": C.number("Before", format: "%,.0f"),
		"after": C.number("After", format: "%,.0f"),
		"note": C.text("Note"),
	], cellStyle: (size_t r, string col, Json v) {
		if (col != "change") return null;
		switch (v.get!string)
		{
			case "added": return "bg:success";
			case "changed": return "bg:warning";
			case "skipped": return "text:muted";
			default: return null;
		}
	});
	auto c = st.columns([1.0, 1, 5]);
	if (c[0].button("Back"))
		go(st, 1);
	if (c[1].button("Apply", type: "primary", disabled: counts["added"] + counts["changed"] == 0))
	{
		// new suppliers first, then the cells
		string[string] idOf;
		foreach (x; s.suppliers)
			idOf[x.name] = x.id;
		string[3][] cells;
		double[] amounts;
		foreach (ch; changes)
		{
			if (ch.kind != "added" && ch.kind != "changed")
				continue;
			if (ch.supplier !in idOf)
				idOf[ch.supplier] = s.addSupplier(ch.supplier, "—");
			cells ~= [idOf[ch.supplier], ch.brand, ch.month.to!string];
			amounts ~= ch.after;
		}
		s.applyCells(cells, amounts);
		st.session["import-applied"] = cells.length.to!int;
		go(st, 3);
	}
}

private void done(St st)
{
	st.success("Imported " ~ st.session.get!int("import-applied", 0).to!string ~ " plan cells.", icon: "✅");
	if (st.button("Import another file", type: "primary"))
	{
		foreach (k; ["import-csv", "import-name", "import-map", "import-applied"])
			st.session.remove(k);
		st.resetWidgets("import-file");
		go(st, 0);
	}
}

private import std.algorithm : filter;
