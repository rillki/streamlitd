// streamlitd tables: st.dataframe, st.data_editor and st.table.
// Column configuration (types, formats, widths, pinned/hidden columns, grouped headers, colours),
// a totals row, per-cell styles, sorting, search, CSV, and the config-aware editor.
// Loaded before app.js; app.js calls StTable.render(node, el, mode, api).
window.StTable = (function () {
  "use strict";

  // ------------------------------------------------------------------ formatting
  const TOKENS = ["success", "warning", "error", "info", "muted", "primary"];
  const isNumType = (t) => t === "number" || t === "progress";

  /** The effective column type: the configured one, else from the data. */
  function colType(c) {
    const t = c.cfg.type;
    if (t) return t;
    switch (c.type) {
      case "integer": case "number": return "number";
      case "boolean": return "checkbox";
      case "date": return "date";
      case "datetime": return "datetime";
      case "object": return "json";
      default: return "text";
    }
  }

  /** printf-style number formatting: %d %i %u %f %e %s %%, flags + , 0 and space, width, precision. */
  function printf(fmt, v) {
    return fmt.replace(/%([-+ 0,]*)(\d*)(?:\.(\d+))?([diufeEs%])/g, (m, flags, width, prec, conv) => {
      if (conv === "%") return "%";
      let s;
      const p = prec === undefined ? null : +prec;
      if (conv === "s") s = String(v);
      else if (conv === "e" || conv === "E") { s = Number(v).toExponential(p === null ? 6 : p); if (conv === "E") s = s.toUpperCase(); }
      else {
        const n = conv === "f" ? Number(v) : Math.round(Number(v));
        const digits = conv === "f" ? (p === null ? 6 : p) : 0;
        const abs = Math.abs(n);
        s = flags.includes(",")
          ? abs.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits })
          : abs.toFixed(digits);
        const zero = /^[0.,]*$/.test(s); // "-0.0" shows as "0.0"
        if (n < 0 && !zero) s = "-" + s;
        else if (flags.includes("+")) s = "+" + s;
        else if (flags.includes(" ")) s = " " + s;
      }
      const w = +width || 0;
      if (s.length < w) s = flags.includes("-") ? s.padEnd(w) : flags.includes("0") && conv !== "s" ? s.replace(/^([+-]?)/, (x) => x + "0".repeat(w - s.length)) : s.padStart(w);
      return s;
    });
  }

  function formatNumber(v, fmt, isInt) {
    if (typeof v !== "number") return v === null || v === undefined ? "" : String(v);
    switch (fmt) {
      case undefined: case null: case "":
        if (isInt || Number.isInteger(v)) return String(v);
        { const a = Math.abs(v); return a !== 0 && (a < 1e-4 || a >= 1e15) ? v.toExponential(4) : String(+v.toFixed(4)); }
      case "plain": return String(v);
      case "localized": return v.toLocaleString(undefined, { maximumFractionDigits: isInt ? 0 : 2 });
      case "percent": return (v * 100).toLocaleString(undefined, { maximumFractionDigits: 2 }) + "%";
      case "compact": return v.toLocaleString(undefined, { notation: "compact", maximumFractionDigits: 1 });
      case "dollar": return v.toLocaleString(undefined, { style: "currency", currency: "USD" });
      case "euro": return v.toLocaleString(undefined, { style: "currency", currency: "EUR" });
      case "scientific": return v.toExponential(2);
      default: return fmt.includes("%") ? printf(fmt, v) : String(v);
    }
  }

  // "2026-01-31", "2026-01-31T09:05:00", "09:05:00" -> parts
  function dateParts(v) {
    const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(String(v));
    if (m) return { y: +m[1], mo: +m[2], d: +m[3], h: +(m[4] || 0), mi: +(m[5] || 0), s: +(m[6] || 0), hasTime: !!m[4] };
    const t = /^(\d{1,2}):(\d{2})(?::(\d{2}))?/.exec(String(v));
    if (t) return { y: 1970, mo: 1, d: 1, h: +t[1], mi: +t[2], s: +(t[3] || 0), hasTime: true, timeOnly: true };
    return null;
  }
  const pad2 = (n) => String(n).padStart(2, "0");
  function formatDate(v, fmt, type) {
    if (v === null || v === undefined || v === "") return "";
    const p = dateParts(v);
    if (!p) return String(v);
    const js = new Date(p.y, p.mo - 1, p.d, p.h, p.mi, p.s);
    if (!fmt || fmt === "localized") {
      if (type === "time" || p.timeOnly) return js.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
      if (type === "datetime" && fmt === "localized") return js.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
      if (fmt === "localized") return js.toLocaleDateString(undefined, { dateStyle: "medium" });
      return String(v);
    }
    return fmt.replace(/YYYY|YY|MMMM|MMM|MM|M|DD|D|HH|H|mm|ss/g, (t) => {
      switch (t) {
        case "YYYY": return String(p.y);
        case "YY": return pad2(p.y % 100);
        case "MMMM": return js.toLocaleDateString(undefined, { month: "long" });
        case "MMM": return js.toLocaleDateString(undefined, { month: "short" });
        case "MM": return pad2(p.mo);
        case "M": return String(p.mo);
        case "DD": return pad2(p.d);
        case "D": return String(p.d);
        case "HH": return pad2(p.h);
        case "H": return String(p.h);
        case "mm": return pad2(p.mi);
        case "ss": return pad2(p.s);
      }
      return t;
    });
  }

  /** The text a cell shows. */
  function cellText(v, c) {
    const t = colType(c);
    if (v === null || v === undefined) return c.cfg.format || c.cfg.type ? "" : "None";
    switch (t) {
      case "number": case "progress": return formatNumber(v, c.cfg.format, c.type === "integer");
      case "date": case "datetime": case "time": return formatDate(v, c.cfg.format, t);
      case "checkbox": return v ? "✓" : "";
      case "link": return c.cfg.display || String(v);
      case "json": return typeof v === "object" ? JSON.stringify(v) : String(v);
      default: return typeof v === "object" ? JSON.stringify(v) : String(v);
    }
  }

  function cmpValues(a, b) {
    const an = a === null || a === undefined || a === "", bn = b === null || b === undefined || b === "";
    if (an || bn) return an === bn ? 0 : an ? 1 : -1; // empty last
    if (typeof a === "number" && typeof b === "number") return a - b;
    if (typeof a === "boolean" && typeof b === "boolean") return (a ? 1 : 0) - (b ? 1 : 0);
    return String(a).localeCompare(String(b), undefined, { numeric: true });
  }

  /** Aggregate a column over rows for the totals row. */
  function aggregate(kind, values) {
    const nums = values.filter((x) => typeof x === "number");
    switch (kind) {
      case "sum": return nums.reduce((s, x) => s + x, 0);
      case "mean": return nums.length ? nums.reduce((s, x) => s + x, 0) / nums.length : null;
      case "min": return nums.length ? Math.min(...nums) : null;
      case "max": return nums.length ? Math.max(...nums) : null;
      case "count": return values.filter((x) => x !== null && x !== undefined && x !== "").length;
    }
    return null;
  }
  const AGGS = new Set(["sum", "mean", "min", "max", "count"]);

  // style tokens: "bg:success text:error bold bg:#fff3cd"
  const HEX = /^#[0-9a-fA-F]{3,8}$/;
  function applyStyle(td, spec) {
    if (!spec) return;
    for (const tok of String(spec).split(/\s+/)) {
      if (!tok) continue;
      if (tok === "bold") td.classList.add("cs-bold");
      else if (tok === "italic") td.classList.add("cs-italic");
      else {
        const m = /^(bg|text):(.+)$/.exec(tok);
        if (!m) continue;
        if (TOKENS.includes(m[2])) td.classList.add("cs-" + m[1] + "-" + m[2]);
        else if (HEX.test(m[2])) td.style[m[1] === "bg" ? "background" : "color"] = m[2];
      }
    }
  }
  const WIDTHS = { small: 75, medium: 200, large: 400 };
  // per table (key or columns): open tree groups, scroll position; survives reruns
  const MEMO = {};
  const safeUrl = (u) => /^(https?:|mailto:|\/|\.\/|[^:]*$)/i.test(String(u).trim());

  // ------------------------------------------------------------------ render
  /**
   * mode: "dataframe" | "editor" | "table".
   * api: { h, widgetChanged, StUI }
   */
  function render(node, el, mode, api) {
    const { h } = api;
    const editable = mode === "editor";
    const isStatic = mode === "table";
    const config = el.config || {};
    const allCols = (el.columns || []).map((c, i) => ({ ...c, i, cfg: config[c.name] || {} }));
    const byName = Object.fromEntries(allCols.map((c) => [c.name, c]));
    // pinned columns first, hidden ones out
    const groupBy = mode === "dataframe" ? el.groupBy || [] : [];
    const shown = allCols.filter((c) => !c.cfg.hidden && !groupBy.includes(c.name));
    const cols = shown.filter((c) => c.cfg.pinned).concat(shown.filter((c) => !c.cfg.pinned));
    const data = el.data || [];
    const styles = el.styles || {};
    const totals = el.totals || null;
    const label = (c) => c.cfg.label || c.name;

    // heat scales over all rows
    const heat = {};
    for (const c of cols) if (c.cfg.background === "heat") {
      const nums = data.map((r) => r[c.i]).filter((x) => typeof x === "number");
      const lo = c.cfg.min !== undefined ? c.cfg.min : Math.min(...nums), hi = c.cfg.max !== undefined ? c.cfg.max : Math.max(...nums);
      heat[c.i] = [lo, hi];
    }

    const testid = editable ? "st-data-editor" : isStatic ? "st-table" : "st-dataframe";
    const container = h("div", { class: "df-container" + (isStatic ? " static" : ""), "data-testid": testid });
    const toolbar = h("div", { class: "df-toolbar" });
    const wrap = h("div", { class: isStatic ? "static-wrap" : "df-wrap" });
    if (!isStatic) {
      if (el.height > 0) { wrap.style.height = el.height + "px"; wrap.style.maxHeight = el.height + "px"; }
      else if (el.maxHeight > 0) wrap.style.maxHeight = el.maxHeight + "px";
    }
    if (!isStatic) container.append(toolbar);
    container.append(wrap);
    node.wrap.appendChild(container);

    let sortCol = -1, sortDir = 1, filter = "";
    const state = editable ? JSON.parse(JSON.stringify(el.value || {})) : null;
    if (state) { state.edited = state.edited || {}; state.added = state.added || []; state.deleted = state.deleted || []; }
    const selected = new Set();
    const disabledCols = new Set(el.disabledCols || []);

    if (mode === "dataframe") {
      const search = h("input", { type: "search", placeholder: "Search", "aria-label": "Search table" });
      search.addEventListener("input", () => { filter = search.value.toLowerCase(); draw(); });
      const dl = h("button", { type: "button", text: "⬇ CSV", title: "Download as CSV" });
      dl.addEventListener("click", () => downloadCsv(h, cols, data, label));
      toolbar.append(search, dl);
    }

    const commit = () => api.widgetChanged(el, JSON.parse(JSON.stringify(state)));
    const setCell = (ri, col, v) => {
      const src = el.rowMap[ri];
      if (src >= 0) {
        state.edited[src] = state.edited[src] || {};
        state.edited[src][col.name] = v;
      } else {
        const k = -src - 1;
        state.added[k] = state.added[k] || {};
        state.added[k][col.name] = v;
      }
      commit();
    };

    function widthStyle(td, c) {
      const w = WIDTHS[c.cfg.width] || (c.cfg.width ? +c.cfg.width : 0);
      if (w) { td.style.width = w + "px"; td.style.minWidth = w + "px"; td.style.maxWidth = w + "px"; }
    }

    // display cell
    function displayCell(row, c, ri) {
      const v = row[c.i];
      const t = colType(c);
      const cls = ["c-" + t];
      if (isNumType(t)) cls.push("num");
      if (v === null || v === undefined) cls.push("null");
      const td = h("td", { class: cls.join(" ") });
      const text = cellText(v, c);
      if (t === "progress" && typeof v === "number") {
        const lo = c.cfg.min !== undefined ? c.cfg.min : 0, hi = c.cfg.max !== undefined ? c.cfg.max : 100;
        const pct = hi > lo ? Math.max(0, Math.min(100, ((v - lo) / (hi - lo)) * 100)) : 0;
        td.appendChild(h("div", { class: "cell-progress" },
          h("span", { class: "cell-progress-bar", "aria-hidden": "true" }, h("span", { style: { width: pct + "%" } })),
          h("span", { class: "cell-progress-text", text })));
      } else if (t === "link" && v) {
        const url = String(v);
        td.appendChild(safeUrl(url) ? h("a", { href: url, target: "_blank", rel: "noopener noreferrer", text }) : h("span", { text }));
      } else {
        td.appendChild(h("span", { class: "cell-text", text }));
      }
      if (c.cfg.detail && byName[c.cfg.detail]) {
        const dc = byName[c.cfg.detail];
        const dv = row[dc.i];
        if (dv !== null && dv !== undefined) td.appendChild(h("div", { class: "cell-detail", text: cellText(dv, dc) }));
      }
      td.title = text;
      // colours: sign, token, background, heat
      if (c.cfg.color === "sign" && typeof v === "number") { if (v > 0) td.classList.add("cs-text-success"); else if (v < 0) td.classList.add("cs-text-error"); }
      else if (TOKENS.includes(c.cfg.color)) td.classList.add("cs-text-" + c.cfg.color);
      const bg = c.cfg.background;
      if (bg === "heat" && typeof v === "number" && heat[c.i]) {
        const [lo, hi] = heat[c.i];
        const f = hi > lo ? (v - lo) / (hi - lo) : 0;
        td.style.background = "color-mix(in srgb, var(--primary) " + Math.round(Math.max(0, Math.min(1, f)) * 30) + "%, transparent)";
      } else if (TOKENS.includes(bg)) td.classList.add("cs-bg-" + bg);
      else if (bg && HEX.test(bg)) td.style.background = bg;
      if (ri !== null && ri !== undefined) applyStyle(td, styles[ri + "," + c.i]);
      return td;
    }

    // editor cell
    function editCell(row, c, ri) {
      const v = row[c.i];
      const t = colType(c);
      const td = h("td", { class: "edit c-" + t + (isNumType(t) ? " num" : "") });
      const invalid = (bad) => { td.classList.toggle("invalid", bad); };
      const name = label(c) + " row " + ri;
      if (t === "checkbox") {
        const inp = h("input", { type: "checkbox", "aria-label": name });
        inp.checked = !!v;
        inp.addEventListener("change", () => setCell(ri, c, inp.checked));
        td.appendChild(inp);
      } else if (t === "select") {
        const opts = (c.cfg.options || []).slice();
        const withEmpty = !c.cfg.required;
        const list = (withEmpty ? [""] : []).concat(opts);
        const idx = list.indexOf(v === null || v === undefined ? "" : String(v));
        const cb = api.StUI.combobox({
          label: name, options: list.map((o) => ({ label: o === "" ? "—" : o })), value: idx < 0 ? null : idx,
          onChange: (i) => setCell(ri, c, list[i] === "" ? null : list[i]),
        });
        td.appendChild(cb.el);
        invalid(c.cfg.required && (v === null || v === undefined || v === ""));
      } else if (t === "date") {
        const dp = api.StUI.datePicker({ label: name, value: v || "", onChange: (s) => setCell(ri, c, s || null) });
        dp.input.setAttribute("aria-label", name);
        td.appendChild(dp.el);
      } else {
        const num = isNumType(t);
        const inp = h("input", { type: num ? "number" : "text", "aria-label": name,
          step: num ? (c.cfg.step !== undefined ? c.cfg.step : "any") : null,
          min: num && c.cfg.min !== undefined ? c.cfg.min : null, max: num && c.cfg.max !== undefined ? c.cfg.max : null,
          maxlength: c.cfg.maxChars || null, inputmode: num ? "decimal" : null });
        inp.value = v === null || v === undefined ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v));
        const orig = inp.value;
        const check = () => {
          const s = inp.value;
          if (s === "") return !c.cfg.required;
          if (num) {
            const n = Number(s);
            if (!isFinite(n)) return false;
            if (c.cfg.min !== undefined && n < c.cfg.min) return false;
            if (c.cfg.max !== undefined && n > c.cfg.max) return false;
          }
          return true;
        };
        invalid(!check() && orig !== "");
        inp.addEventListener("input", () => invalid(!check()));
        inp.addEventListener("change", () => {
          if (inp.value === orig) return;
          if (!check()) { invalid(true); inp.setAttribute("aria-invalid", "true"); return; }
          inp.removeAttribute("aria-invalid");
          let nv = inp.value;
          if (num) nv = nv === "" ? null : Number(nv);
          else if (nv === "") nv = null;
          setCell(ri, c, nv);
        });
        inp.addEventListener("keydown", (ev) => { if (ev.key === "Enter") inp.blur(); });
        td.appendChild(inp);
      }
      return td;
    }

    const hasGroups = cols.some((c) => c.cfg.group);
    const firstCol = cols[0];

    // ---- selection and tree state (st.dataframe only)
    const selMode = mode === "dataframe" && el.selectionMode ? el.selectionMode : null;
    const multi = selMode === "multi-row";
    const tree = mode === "dataframe" && groupBy.length > 0;
    const keyCol = el.rowKey && byName[el.rowKey] ? byName[el.rowKey] : null;
    const readSel = (v) => {
      v = v || {};
      return { rows: new Set(v.rows || []), cell: (v.cells && v.cells[0]) || null, group: v.group && v.group.length ? v.group.slice() : null };
    };
    let sel = readSel(el.value);
    const memoKey = el.memoKey || el.treeKey || el.id || null;
    const memo = memoKey ? (MEMO[memoKey] = MEMO[memoKey] || {}) : {};
    if (tree && !memo.open) memo.open = new Set();
    const pk = (path) => JSON.stringify(path);
    let anchor = -1; // multi-row: Shift-click range start (display position)
    let entries = [];

    function sendSel() {
      const rows = Array.from(sel.rows);
      const v = { rows, cells: sel.cell ? [sel.cell] : [], group: sel.group || [], n: data.length };
      if (keyCol) v.keys = rows.map((ri) => data[ri][keyCol.i]);
      api.widgetChanged(el, v);
    }

    // ---- tree: group the shown rows by the groupBy columns
    function buildTree(leaves) {
      const root = { path: [], children: new Map(), leaves: [], all: leaves, depth: -1 };
      for (const ri of leaves) {
        let n = root;
        groupBy.forEach((g, d) => {
          const v = data[ri][byName[g].i];
          const lab = v === null || v === undefined ? "" : String(v);
          if (!n.children.has(lab)) n.children.set(lab, { path: n.path.concat([lab]), label: lab, children: new Map(), leaves: [], all: [], depth: d });
          n = n.children.get(lab);
          n.all.push(ri);
        });
        n.leaves.push(ri);
      }
      return root;
    }
    function groupValue(g, c) {
      const spec = totals && totals[c.name];
      if (AGGS.has(spec)) return aggregate(spec, g.all.map((ri) => data[ri][c.i]));
      return null;
    }
    function flatten(node, out, searching) {
      let groups = Array.from(node.children.values());
      if (sortCol >= 0) {
        const c = allCols[sortCol];
        groups.sort((a, b) => sortDir * cmpValues(c === firstCol ? a.label : groupValue(a, c), c === firstCol ? b.label : groupValue(b, c)));
      }
      for (const g of groups) {
        const open = searching || memo.open.has(pk(g.path));
        out.push({ kind: "group", g, depth: g.depth, open });
        if (open) flatten(g, out, searching);
      }
      let leaves = node.leaves.slice();
      if (sortCol >= 0) leaves.sort((a, b) => sortDir * cmpValues(data[a][sortCol], data[b][sortCol]));
      for (const ri of leaves) out.push({ kind: "leaf", ri, depth: groupBy.length });
    }

    function head(t) {
      const thead = h("thead");
      const lead = () => {
        const cells = [];
        if (editable && el.numRows === "dynamic") cells.push(h("th", { class: "rowsel idx" }));
        if (multi) cells.push(h("th", { class: "rowsel idx" }));
        if (!el.hideIndex) cells.push(h("th", { class: "idx" }));
        return cells;
      };
      // grouped headers: a row above with one cell per run of columns of the same group
      if (hasGroups) {
        const gr = h("tr", { class: "group-row" }, ...lead());
        for (let k = 0; k < cols.length;) {
          const g = cols[k].cfg.group || "";
          let n = 1;
          while (k + n < cols.length && (cols[k + n].cfg.group || "") === g && g) n++;
          gr.appendChild(h("th", { class: "group" + (g ? " named" : ""), colspan: n > 1 ? String(n) : null, scope: g ? "colgroup" : null, text: g }));
          k += n;
        }
        thead.appendChild(gr);
      }
      const hr = h("tr");
      if (editable && el.numRows === "dynamic") hr.appendChild(h("th", { class: "rowsel idx", text: "" }));
      if (multi) {
        // select all rows shown
        const all = h("input", { type: "checkbox", "aria-label": "Select all rows" });
        const leaves = entries.filter((e) => e.kind === "leaf").map((e) => e.ri);
        all.checked = leaves.length > 0 && leaves.every((ri) => sel.rows.has(ri));
        all.indeterminate = !all.checked && leaves.some((ri) => sel.rows.has(ri));
        all.addEventListener("change", () => {
          leaves.forEach((ri) => (all.checked ? sel.rows.add(ri) : sel.rows.delete(ri)));
          sendSel();
          draw();
        });
        hr.appendChild(h("th", { class: "rowsel idx" }, all));
      }
      if (!el.hideIndex) hr.appendChild(h("th", { class: "idx", text: "" }));
      cols.forEach((c, k) => {
        const t2 = colType(c);
        const groupStart = hasGroups && c.cfg.group && (k === 0 || cols[k - 1].cfg.group !== c.cfg.group);
        const th = h("th", { class: (isNumType(t2) ? "num " : "") + (c.cfg.pinned ? "pinned " : "") + (groupStart ? "gstart " : "") + (c.cfg.help ? "has-help" : ""),
          scope: "col", title: c.cfg.help || null, "aria-sort": c.i === sortCol ? (sortDir > 0 ? "ascending" : "descending") : null });
        widthStyle(th, c);
        if (isStatic) th.textContent = label(c);
        else {
          const b = h("button", { type: "button", class: "th-sort" + (c.i === sortCol ? (sortDir > 0 ? " sorted-asc" : " sorted-desc") : ""), text: label(c),
            "aria-label": "Sort by " + label(c) + (c.cfg.help ? " — " + c.cfg.help : "") });
          b.addEventListener("click", () => {
            if (sortCol === c.i) { if (sortDir > 0) sortDir = -1; else { sortCol = -1; sortDir = 1; } }
            else { sortCol = c.i; sortDir = 1; }
            draw();
            const again = wrap.querySelectorAll("thead tr:last-child th .th-sort")[k];
            if (again) again.focus();
          });
          th.appendChild(b);
        }
        hr.appendChild(th);
      });
      thead.appendChild(hr);
      t.appendChild(thead);
    }

    function decorate(td, c, k) {
      if (c.cfg.pinned) td.classList.add("pinned");
      if (hasGroups && c.cfg.group && (k === 0 || cols[k - 1].cfg.group !== c.cfg.group)) td.classList.add("gstart");
      widthStyle(td, c);
      return td;
    }

    // editor and static tables: one row per data row
    function plainBody(tb, rows) {
      for (const ri of rows) {
        const row = data[ri];
        const tr = h("tr", { class: editable && el.rowMap && el.rowMap[ri] < 0 ? "added" : null });
        if (editable && el.numRows === "dynamic") {
          const cb = h("input", { type: "checkbox", "aria-label": "Select row " + ri });
          cb.checked = selected.has(ri);
          cb.addEventListener("change", () => { if (cb.checked) selected.add(ri); else selected.delete(ri); delBtn.disabled = selected.size === 0; });
          tr.appendChild(h("td", { class: "rowsel idx" }, cb));
        }
        if (!el.hideIndex) tr.appendChild(h("td", { class: "idx", text: String(ri) }));
        cols.forEach((c, k) => {
          const canEdit = editable && !el.disabled && !disabledCols.has(c.name) && !c.cfg.disabled && c.cfg.type !== "progress" && c.cfg.type !== "link";
          // styles are keyed by the row of the original frame; editor rows are not
          const td = canEdit ? editCell(row, c, ri) : displayCell(row, c, editable ? (el.rowMap ? el.rowMap[ri] : null) : ri);
          tr.appendChild(decorate(td, c, k));
        });
        tb.appendChild(tr);
      }
    }

    // st.dataframe: rows that can be selected, and tree rows
    const indent = (depth) => (0.5 + depth * 1.25 + (tree ? 1.4 : 0)) + "rem";
    // color: "sign" also colours group sums and totals (a negative Δ total is red too)
    function signColor(td, c, v) {
      if (c.cfg.color !== "sign" || typeof v !== "number") return;
      if (v > 0) td.classList.add("cs-text-success"); else if (v < 0) td.classList.add("cs-text-error");
    }

    function interactiveBody(tb) {
      entries.forEach((e, pos) => {
        let tr;
        if (e.kind === "group") {
          const g = e.g;
          const selectedGroup = sel.group && pk(sel.group) === pk(g.path);
          tr = h("tr", { class: "tree-group level-" + e.depth + (selectedGroup ? " selected" : ""), "data-pos": String(pos), tabindex: "-1",
            "aria-level": String(e.depth + 1), "aria-expanded": String(e.open), "aria-selected": selMode === "single-row" ? String(!!selectedGroup) : null });
          if (multi) tr.appendChild(h("td", { class: "rowsel idx" }));
          if (!el.hideIndex) tr.appendChild(h("td", { class: "idx" }));
          cols.forEach((c, k) => {
            let td;
            if (k === 0) {
              const tog = h("button", { type: "button", class: "tree-toggle", tabindex: "-1", "aria-label": (e.open ? "Collapse " : "Expand ") + (g.label || "(empty)"),
                text: e.open ? "▾" : "▸" });
              td = h("td", { class: "tree-cell", style: { paddingLeft: (0.5 + e.depth * 1.25) + "rem" } },
                tog, h("span", { class: "tree-label", text: g.label || "—" }), h("span", { class: "tree-count", text: " " + g.all.length }));
            } else {
              const v = groupValue(g, c);
              td = h("td", { class: isNumType(colType(c)) ? "num" : null, text: v === null ? "" : cellText(v, c.cfg.type === "progress" ? { ...c, cfg: { ...c.cfg, type: "number" } } : c) });
              signColor(td, c, v);
            }
            tr.appendChild(decorate(td, c, k));
          });
        } else {
          const ri = e.ri, row = data[ri];
          const isSel = sel.rows.has(ri);
          tr = h("tr", { class: (isSel ? "selected" : "") + (tree ? " tree-leaf" : ""), "data-pos": String(pos), tabindex: "-1",
            "aria-level": tree ? String(e.depth + 1) : null, "aria-selected": selMode && selMode !== "single-cell" ? String(isSel) : null });
          if (multi) {
            const cb = h("input", { type: "checkbox", tabindex: "-1", "aria-label": "Select row " + ri });
            cb.checked = isSel;
            tr.appendChild(h("td", { class: "rowsel idx" }, cb));
          }
          if (!el.hideIndex) tr.appendChild(h("td", { class: "idx", text: String(ri) }));
          cols.forEach((c, k) => {
            const td = displayCell(row, c, ri);
            if (k === 0 && tree) td.style.paddingLeft = indent(e.depth);
            if (selMode === "single-cell") {
              td.tabIndex = -1;
              td.dataset.col = c.name;
              const isCell = sel.cell && sel.cell[0] === ri && sel.cell[1] === c.name;
              if (isCell) td.classList.add("selected");
              td.setAttribute("aria-selected", String(!!isCell));
            }
            tr.appendChild(decorate(td, c, k));
          });
        }
        tb.appendChild(tr);
      });
    }

    function totalsRow(t, rows) {
      const fr = h("tr", { class: "totals" });
      if (multi) fr.appendChild(h("td", { class: "rowsel idx" }));
      if (!el.hideIndex) fr.appendChild(h("td", { class: "idx" }));
      cols.forEach((c, k) => {
        const spec = totals[c.name];
        let td;
        if (spec === undefined) td = h("td", { class: isNumType(colType(c)) ? "num" : null });
        else if (AGGS.has(spec)) {
          const val = aggregate(spec, rows.map((ri) => data[ri][c.i]));
          const shownText = val === null ? "" : spec === "count" ? String(val) : cellText(val, c.cfg.type === "progress" ? { ...c, cfg: { ...c.cfg, type: "number" } } : c);
          td = h("td", { class: "num", text: shownText, title: spec + ": " + shownText });
          if (spec !== "count") signColor(td, c, val);
        } else td = h("th", { scope: "row", text: spec });
        fr.appendChild(decorate(td, c, k));
      });
      t.appendChild(h("tfoot", null, fr));
    }

    // identity of the focused row/cell, to put focus back after redrawing
    const identity = (elt) => {
      const tr = elt && elt.closest && elt.closest("tbody tr");
      if (!tr || !tr.dataset.pos) return null;
      const e = entries[+tr.dataset.pos];
      if (!e) return null;
      const base = e.kind === "group" ? "g" + pk(e.g.path) : "r" + e.ri;
      return elt.tagName === "TD" && elt.dataset.col ? base + "|" + elt.dataset.col : base;
    };

    const draw = () => {
      const hadFocus = wrap.contains(document.activeElement) ? identity(document.activeElement) : null;
      let rows = data.map((r, i) => i);
      const searchCols = cols.concat(groupBy.map((g) => byName[g]).filter(Boolean));
      if (filter) rows = rows.filter((i) => searchCols.some((c) => cellText(data[i][c.i], c).toLowerCase().includes(filter)));
      if (tree) {
        if (!memo.started) {
          // `expanded` levels open at first
          memo.started = true;
          const openTo = el.expanded || 0;
          (function walk(n) { for (const g of n.children.values()) { if (g.depth < openTo) memo.open.add(pk(g.path)); walk(g); } })(buildTree(data.map((r, i) => i)));
        }
        entries = [];
        flatten(buildTree(rows), entries, !!filter);
      } else {
        if (sortCol >= 0) rows.sort((a, b) => sortDir * cmpValues(data[a][sortCol], data[b][sortCol]));
        entries = rows.map((ri) => ({ kind: "leaf", ri, depth: 0 }));
      }
      const interactive = mode === "dataframe";
      const t = h("table", { class: (isStatic ? "static" : "df") + (hasGroups ? " grouped" : "") + (selMode ? " selectable sel-" + selMode : "") + (tree ? " tree" : ""),
        role: interactive && (selMode || tree) ? (tree ? "treegrid" : "grid") : null, "aria-multiselectable": multi ? "true" : null });
      head(t);
      const tb = h("tbody");
      if (interactive) interactiveBody(tb); else plainBody(tb, rows);
      t.appendChild(tb);
      if (totals && !editable) totalsRow(t, rows);
      wrap.replaceChildren(t);
      pinColumns(t);
      if (interactive && (selMode || tree)) {
        // one tab stop: the focused row (or cell), else the first
        let target = null;
        if (hadFocus) for (const r of tb.querySelectorAll("tr")) {
          if (identity(r) === hadFocus) { target = r; break; }
          for (const td of r.querySelectorAll("td[data-col]")) if (identity(td) === hadFocus) { target = td; break; }
          if (target) break;
        }
        const first = selMode === "single-cell" ? tb.querySelector("tr:not(.tree-group) td[data-col]") || tb.querySelector("tr") : tb.querySelector("tr");
        const stop = target || first;
        if (stop) { stop.tabIndex = 0; if (target) target.focus({ preventScroll: true }); }
      }
    };

    // ---- clicks and keys on rows (st.dataframe)
    function toggleOpen(g, open) {
      const k = pk(g.path);
      if (open === undefined ? memo.open.has(k) : !open) memo.open.delete(k); else memo.open.add(k);
      draw();
    }
    function activate(e, ev, td) {
      if (e.kind === "group") {
        if (selMode === "single-row") {
          sel.group = sel.group && pk(sel.group) === pk(e.g.path) ? null : e.g.path.slice();
          sel.rows.clear();
          sendSel();
          draw();
        } else toggleOpen(e.g);
        return;
      }
      if (!selMode) return;
      const ri = e.ri;
      if (selMode === "single-cell") {
        if (!td || !td.dataset.col) return;
        const same = sel.cell && sel.cell[0] === ri && sel.cell[1] === td.dataset.col;
        sel.cell = same ? null : [ri, td.dataset.col];
      } else if (multi) {
        const pos = entries.indexOf(e);
        if (ev && ev.shiftKey && anchor >= 0) {
          const [a, b] = anchor < pos ? [anchor, pos] : [pos, anchor];
          for (let p = a; p <= b; p++) if (entries[p].kind === "leaf") sel.rows.add(entries[p].ri);
        } else if (sel.rows.has(ri)) sel.rows.delete(ri); else sel.rows.add(ri);
        anchor = pos;
      } else {
        const same = sel.rows.has(ri) && sel.rows.size === 1;
        sel.rows = same ? new Set() : new Set([ri]);
        sel.group = null;
      }
      sendSel();
      draw();
    }
    if (mode === "dataframe") {
      wrap.addEventListener("click", (ev) => {
        const tr = ev.target.closest("tbody tr");
        if (!tr || !wrap.contains(tr) || !tr.dataset.pos) return;
        const e = entries[+tr.dataset.pos];
        if (!e) return;
        if (ev.target.closest(".tree-toggle")) { toggleOpen(e.g); return; }
        if (ev.target.closest("a")) return; // links open
        activate(e, ev, ev.target.closest("td"));
      });
      wrap.addEventListener("keydown", (ev) => {
        const cur = document.activeElement;
        const tr = cur && cur.closest && cur.closest("tbody tr");
        if (!tr || !wrap.contains(tr) || !tr.dataset.pos) return;
        const pos = +tr.dataset.pos, e = entries[pos];
        const rowsEls = Array.from(wrap.querySelectorAll("tbody tr"));
        const cellMode = selMode === "single-cell" && cur.tagName === "TD";
        const focusRow = (p) => {
          const r = rowsEls[Math.max(0, Math.min(rowsEls.length - 1, p))];
          if (!r) return;
          let target = r;
          if (cellMode) {
            const ci = Array.from(tr.querySelectorAll("td[data-col]")).indexOf(cur);
            target = r.querySelectorAll("td[data-col]")[ci] || r;
          }
          wrap.querySelectorAll('[tabindex="0"]').forEach((x) => { if (x !== target) x.tabIndex = -1; });
          target.tabIndex = 0;
          target.focus();
        };
        switch (ev.key) {
          case "ArrowDown": focusRow(pos + 1); break;
          case "ArrowUp": focusRow(pos - 1); break;
          case "Home": focusRow(0); break;
          case "End": focusRow(rowsEls.length - 1); break;
          case "ArrowRight":
            if (cellMode) { const n = cur.nextElementSibling; if (n && n.dataset.col) { cur.tabIndex = -1; n.tabIndex = 0; n.focus(); } }
            else if (e.kind === "group") { if (!e.open) toggleOpen(e.g, true); else focusRow(pos + 1); }
            break;
          case "ArrowLeft":
            if (cellMode) { const p = cur.previousElementSibling; if (p && p.dataset.col) { cur.tabIndex = -1; p.tabIndex = 0; p.focus(); } }
            else if (e.kind === "group" && e.open) toggleOpen(e.g, false);
            else if (tree) { for (let p = pos - 1; p >= 0; p--) if (entries[p].kind === "group" && entries[p].depth < e.depth) { focusRow(p); break; } }
            break;
          case " ": case "Enter": activate(e, ev, cellMode ? cur : null); break;
          default: return;
        }
        ev.preventDefault();
      });
      if (tree) {
        const expandAll = h("button", { type: "button", text: "Expand all", title: "Open every group" });
        const collapseAll = h("button", { type: "button", text: "Collapse all", title: "Close every group" });
        expandAll.addEventListener("click", () => {
          (function walk(n) { for (const g of n.children.values()) { memo.open.add(pk(g.path)); walk(g); } })(buildTree(data.map((r, i) => i)));
          draw();
        });
        collapseAll.addEventListener("click", () => { memo.open.clear(); draw(); });
        toolbar.prepend(expandAll, collapseAll);
      }
      // keep the scroll position across reruns (keyed tables)
      if (memoKey) {
        if (memo.scroll) requestAnimationFrame(() => { wrap.scrollTop = memo.scroll[0]; wrap.scrollLeft = memo.scroll[1]; });
        wrap.addEventListener("scroll", () => { memo.scroll = [wrap.scrollTop, wrap.scrollLeft]; }, { passive: true });
      }
      if (selMode) node.update = (e2) => { el = e2; sel = readSel(e2.value); draw(); };
    }

    // pinned columns stick at the cumulative width of the ones before them
    function pinColumns(t) {
      if (!t.querySelector(".pinned")) return;
      requestAnimationFrame(() => {
        const head = t.querySelector("thead tr:last-child");
        if (!head) return;
        const lefts = [];
        let x = 0;
        for (const cell of head.children) {
          lefts.push(x);
          if (cell.classList.contains("pinned") || cell.classList.contains("idx")) x += cell.offsetWidth;
        }
        for (const tr of t.querySelectorAll("tr:not(.group-row)"))
          Array.from(tr.children).forEach((cell, k) => { if (cell.classList.contains("pinned")) cell.style.left = lefts[k] + "px"; });
      });
    }

    let delBtn = null;
    if (editable && el.numRows === "dynamic" && !el.disabled) {
      const add = h("button", { type: "button", class: "st-btn", text: "+ Add row" });
      delBtn = h("button", { type: "button", class: "st-btn", text: "Delete selected", disabled: true });
      // maxRows: no more rows than the app allows (the server ignores extra ones anyway)
      if (el.maxRows > 0 && (el.rowMap || []).length >= el.maxRows) { add.disabled = true; add.title = "At most " + el.maxRows + " rows"; }
      add.addEventListener("click", () => { state.added.push({}); commit(); });
      delBtn.addEventListener("click", () => {
        const addedIdx = [];
        selected.forEach((ri) => {
          const src = el.rowMap[ri];
          if (src >= 0) state.deleted.push(src); else addedIdx.push(-src - 1);
        });
        addedIdx.sort((a, b) => b - a).forEach((k) => state.added.splice(k, 1));
        selected.clear();
        commit();
      });
      container.appendChild(h("div", { class: "editor-actions" }, add, delBtn));
    }
    draw();
  }

  function downloadCsv(h, cols, data, label) {
    const q = (s) => (/[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s);
    const lines = [cols.map((c) => q(label(c))).join(",")];
    data.forEach((r) => lines.push(cols.map((c) => { const v = r[c.i]; return q(v === null || v === undefined ? "" : typeof v === "object" ? JSON.stringify(v) : String(v)); }).join(",")));
    const blob = new Blob([lines.join("\n") + "\n"], { type: "text/csv" });
    const a = h("a", { href: URL.createObjectURL(blob), download: "data.csv" });
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }

  return { render, formatNumber, formatDate, printf };
})();
