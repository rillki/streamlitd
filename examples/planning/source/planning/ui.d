/// Shared pieces of the planning pages: the plan as a table and back, number formats.
module planning.ui;

import std.algorithm : canFind, map, sum;
import std.array : array;
import std.conv : to;
import std.string : strip;
import streamlitd;
import planning.store;

alias C = ColumnConfig;

/// Column name of a month: "m01".."m12".
string monthCol(int m) { import std.format : format; return format("m%02d", m); }

/// The plan as an editable frame: supplier, brand, one column per month.
DataFrame planFrame(Store s)
{
	// the id is hidden: it ties a row to its brand, so a renamed brand keeps its history
	string[] names = ["id", "supplier", "brand"];
	foreach (m; 1 .. 13)
		names ~= monthCol(m);
	Json[][] rows;
	foreach (b; s.brands)
	{
		Json[] r = [Json(b.id), Json(s.supplierName(b.supplier)), Json(b.name)];
		foreach (m; 0 .. 12)
			r ~= Json(b.plan[m]);
		rows ~= r;
	}
	return DataFrame.fromRows(names, rows);
}

/// Columns of the plan editor: closed months are read-only.
ColumnConfig[string] planColumns(Store s)
{
	ColumnConfig[string] c = [
		"supplier": C.select("Supplier", s.suppliers.map!(x => x.name).array, required: true),
		"id": C.hide(),
		"brand": C.text("Brand", required: true, pinned: true, maxChars: maxName),
	];
	foreach (m; 1 .. 13)
		c[monthCol(m)] = C.number(monthNames[m - 1], format: "%,.0f", min: 0, max: maxAmount, step: 50, disabled: isClosed(m),
			group: isClosed(m) ? "Closed" : "Open months", help: isClosed(m) ? "Closed: the fact is known" : null);
	return c;
}

/// Read an edited plan frame back into brands; `problems` gets what is wrong with it.
Brand[] brandsFrom(DataFrame df, Store s, out string[] problems)
{
	string[string] idOf;
	foreach (x; s.suppliers)
		idOf[x.name] = x.id;
	Brand[] r;
	bool[string] seen;
	foreach (i; 0 .. df.length)
	{
		auto sup = df.cell(i, "supplier").opt!string(null);
		auto name = df.cell(i, "brand").opt!string(null).strip;
		auto row = "Row " ~ (i + 1).to!string ~ ": ";
		if (!sup.length || sup !in idOf) { problems ~= row ~ "choose a supplier."; continue; }
		if (!name.length) { problems ~= row ~ "the brand has no name."; continue; }
		if (sup ~ "/" ~ name in seen) { problems ~= row ~ name ~ " (" ~ sup ~ ") is listed twice."; continue; }
		if (r.length >= maxBrands) { problems ~= "At most " ~ maxBrands.to!string ~ " brands."; break; }
		seen[sup ~ "/" ~ name] = true;
		Brand b;
		b.id = df.cell(i, "id").opt!string(null); // null for new rows
		b.supplier = idOf[sup];
		b.name = name;
		foreach (m; 0 .. 12)
		{
			auto v = df.cell(i, monthCol(m + 1));
			b.plan[m] = v.type == Json.Type.float_ ? v.get!double : v.type == Json.Type.int_ ? v.get!long : 0;
		}
		r ~= b;
	}
	return r;
}

/// The changes as a table for review.
DataFrame changesFrame(PlanChange[] cs)
{
	Json[][] rows;
	foreach (c; cs)
		rows ~= [Json(c.kind), Json(c.supplier), Json(c.brand), Json(c.month ? monthNames[c.month - 1] : "—"),
			Json(c.before), Json(c.after), Json(c.after - c.before)];
	return DataFrame.fromRows(["change", "supplier", "brand", "month", "before", "after", "delta"], rows);
}

ColumnConfig[string] changeColumns()
{
	return [
		"change": C.text("Change", width: "small"),
		"supplier": C.text("Supplier"),
		"brand": C.text("Brand"),
		"month": C.text("Month", width: "small"),
		"before": C.number("Before", format: "%,.0f"),
		"after": C.number("After", format: "%,.0f"),
		"delta": C.number("Δ", format: "%+,.0f", color: "sign"),
	];
}

/// Colours of the change table by kind: added green, removed red, changed yellow.
string delegate(size_t, string, Json) changeStyleFor(DataFrame df)
{
	return (size_t row, string col, Json v) {
		if (col != "change")
			return null;
		switch (df.cell(row, "change").get!string)
		{
			case "added": return "bg:success";
			case "removed": return "bg:error";
			case "renamed": return "bg:info";
			default: return "bg:warning";
		}
	};
}
