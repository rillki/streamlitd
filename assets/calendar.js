// streamlitd calendar grid (st.calendarGrid): rows × days or weeks, markers and spans, a summary
// column, expandable rows, sticky name column and header, keyboard navigation between items.
// Loaded before app.js; app.js calls StCalendar.render(node, el, api).
window.StCalendar = (function () {
  "use strict";
  const DAY = 86400000;
  const MEMO = {}; // per grid: open rows, scroll position, last focus token
  const TOKENS = ["success", "warning", "error", "info", "muted", "primary"];
  const toDay = (iso) => { const [y, m, d] = iso.split("-").map(Number); return Date.UTC(y, m - 1, d) / DAY; };
  const iso = (day) => new Date(day * DAY).toISOString().slice(0, 10);
  const fmtLong = (day) => new Date(day * DAY).toLocaleDateString(undefined, { timeZone: "UTC", day: "numeric", month: "long", year: "numeric" });

  function render(node, el, api) {
    const { h } = api;
    const memo = MEMO[el.memoKey] = MEMO[el.memoKey] || {};
    const week = el.unit === "week";
    const d0 = toDay(el.start), d1 = toDay(el.end), today = toDay(el.today);
    // columns: days, or weeks starting on Monday
    const cols = [];
    if (week) {
      let w = d0 - ((new Date(d0 * DAY).getUTCDay() + 6) % 7);
      for (; w <= d1; w += 7) cols.push({ from: Math.max(w, d0), to: Math.min(w + 6, d1), day: w });
    } else for (let d = d0; d <= d1; d++) cols.push({ from: d, to: d, day: d });
    const colOf = (day) => (week ? cols.findIndex((c) => day >= c.from && day <= c.to) : day - d0);

    const rows = el.rows || [];
    const items = el.items || [];
    const children = {};
    rows.forEach((r) => { if (r.parent) (children[r.parent] = children[r.parent] || []).push(r); });
    const depthOf = (r) => { let d = 0; for (let p = r.parent; p; p = (rows.find((x) => x.id === p) || {}).parent) d++; return d; };
    if (!memo.open) {
      memo.open = new Set();
      rows.forEach((r) => { if (children[r.id] && depthOf(r) < (el.expanded || 0)) memo.open.add(r.id); });
    }
    // the focused item's rows open
    const focusItem = el.focus ? items.find((i) => i.id === el.focus) : null;
    if (focusItem && memo.focusToken !== el.focus) {
      for (let p = (rows.find((r) => r.id === focusItem.row) || {}).parent; p; p = (rows.find((r) => r.id === p) || {}).parent) memo.open.add(p);
    }
    const maxValue = Math.max(0, ...items.map((i) => (typeof i.value === "number" ? Math.abs(i.value) : 0)));
    const hasSummary = rows.some((r) => r.summary || typeof r.progress === "number");

    const wrap = h("div", { class: "cal-wrap", "data-testid": "st-calendar-grid" });
    if (el.height > 0) wrap.style.maxHeight = el.height + "px";
    node.wrap.appendChild(wrap);

    function visibleRows() {
      const out = [];
      (function walk(list, depth) {
        for (const r of list) {
          out.push({ r, depth });
          if (children[r.id] && memo.open.has(r.id)) walk(children[r.id], depth + 1);
        }
      })(rows.filter((r) => !r.parent), 0);
      return out;
    }

    function markColor(it) {
      if (TOKENS.includes(it.color)) return "var(--cal-" + it.color + ")";
      if (it.color && /^#[0-9a-fA-F]{3,8}$/.test(it.color)) return it.color;
      return "var(--primary)";
    }
    const send = (v) => api.triggerWidget(el, v);

    function draw() {
      const t = h("table", { class: "cal-grid" + (week ? " weeks" : " days"), "aria-label": "Calendar" });
      // header: months over days or weeks
      const months = h("tr", { class: "cal-months" });
      months.appendChild(h("th", { class: "cal-name", rowspan: "2", scope: "col", text: "" }));
      if (hasSummary) months.appendChild(h("th", { class: "cal-sum", rowspan: "2", scope: "col", text: el.summaryLabel || "" }));
      for (let k = 0; k < cols.length;) {
        const m = new Date(cols[k].from * DAY);
        let n = 1;
        while (k + n < cols.length) {
          const m2 = new Date(cols[k + n].from * DAY);
          if (m2.getUTCMonth() !== m.getUTCMonth() || m2.getUTCFullYear() !== m.getUTCFullYear()) break;
          n++;
        }
        months.appendChild(h("th", { class: "cal-month", colspan: String(n), scope: "colgroup" },
          h("span", { class: "cal-month-label", text: m.toLocaleDateString(undefined, { timeZone: "UTC", month: "long", year: "numeric" }) })));
        k += n;
      }
      const days = h("tr", { class: "cal-days" });
      cols.forEach((c, k) => {
        const dt = new Date(c.from * DAY);
        const we = !week && (dt.getUTCDay() === 0 || dt.getUTCDay() === 6);
        const mstart = k > 0 && (week ? new Date(cols[k - 1].from * DAY).getUTCMonth() !== dt.getUTCMonth() : dt.getUTCDate() === 1);
        const isToday = today >= c.from && today <= c.to;
        const label = week ? "W" + isoWeek(c.day) : String(dt.getUTCDate());
        days.appendChild(h("th", { class: "cal-day" + (we ? " we" : "") + (mstart ? " mstart" : "") + (isToday ? " today" : ""), scope: "col",
          title: week ? fmtLong(c.from) + " – " + fmtLong(c.to) : fmtLong(c.from), text: label, "aria-current": isToday ? "date" : null }));
      });
      t.appendChild(h("thead", null, months, days));

      const tb = h("tbody");
      for (const { r, depth } of visibleRows()) {
        const tr = h("tr", { class: "cal-row level-" + depth + (children[r.id] ? " has-children" : ""), "data-row": r.id });
        const nameCell = h("th", { class: "cal-name", scope: "row", style: { paddingLeft: (0.4 + depth * 1.1) + "rem" } });
        if (children[r.id]) {
          const open = memo.open.has(r.id);
          const tog = h("button", { type: "button", class: "cal-toggle", "aria-expanded": String(open), "aria-label": (open ? "Collapse " : "Expand ") + r.label, text: open ? "▾" : "▸" });
          tog.addEventListener("click", () => { if (memo.open.has(r.id)) memo.open.delete(r.id); else memo.open.add(r.id); draw(); });
          nameCell.appendChild(tog);
        }
        const lab = h("button", { type: "button", class: "cal-row-label", text: r.label, title: r.label });
        lab.addEventListener("click", () => send({ kind: "row", row: r.id }));
        nameCell.appendChild(lab);
        tr.appendChild(nameCell);
        if (hasSummary) {
          const sum = h("td", { class: "cal-sum" });
          if (r.summary) sum.appendChild(h("div", { class: "cal-sum-text", text: r.summary }));
          if (typeof r.progress === "number") {
            const bar = h("div", { class: "cal-progress", role: "img",
              "aria-label": Math.round(r.progress * 100) + "%" + (typeof r.expected === "number" ? ", expected " + Math.round(r.expected * 100) + "%" : "") },
              h("span", { class: "cal-progress-fill", style: { width: Math.max(0, Math.min(1, r.progress)) * 100 + "%" } }));
            if (typeof r.expected === "number") bar.appendChild(h("span", { class: "cal-expected", style: { left: Math.max(0, Math.min(1, r.expected)) * 100 + "%" } }));
            sum.appendChild(bar);
          }
          tr.appendChild(sum);
        }
        const cells = cols.map((c, k) => {
          const dt = new Date(c.from * DAY);
          const we = !week && (dt.getUTCDay() === 0 || dt.getUTCDay() === 6);
          const mstart = k > 0 && (week ? new Date(cols[k - 1].from * DAY).getUTCMonth() !== dt.getUTCMonth() : dt.getUTCDate() === 1);
          const td = h("td", { class: "cal-cell" + (we ? " we" : "") + (mstart ? " mstart" : "") + (today >= c.from && today <= c.to ? " today" : ""), "data-col": String(k) });
          td.addEventListener("click", (ev) => { if (ev.target === td) send({ kind: "cell", row: r.id, date: iso(c.from) }); });
          return td;
        });
        // items of this row: spans as segments over their columns, markers in their column
        const marks = cols.map(() => []);
        for (const it of items) {
          if (it.row !== r.id) continue;
          const s = toDay(it.start), e = it.end ? toDay(it.end) : null;
          if (e !== null) {
            const a = Math.max(s, d0), b = Math.min(e, d1);
            if (a > b) continue;
            const ka = colOf(a), kb = colOf(b);
            for (let k = ka; k <= kb; k++) {
              const seg = h("button", { type: "button", class: "cal-span" + (k === ka ? " first" : "") + (k === kb ? " last" : "") + (it.outline ? " outline" : ""),
                tabindex: "-1", "data-item": it.id, title: (it.label || "") + " · " + fmtLong(s) + " – " + fmtLong(e),
                "aria-label": (it.label || it.id) + ", " + fmtLong(s) + " – " + fmtLong(e), "aria-hidden": k === ka ? null : "true" });
              seg.style.setProperty("--cal-color", markColor(it));
              seg.addEventListener("click", () => send({ kind: "item", item: it.id, row: r.id, date: iso(it.start ? s : a) }));
              cells[k].appendChild(seg);
            }
            continue;
          }
          if (s < d0 || s > d1) continue;
          marks[colOf(s)].push(it);
        }
        marks.forEach((list, k) => {
          const shown = list.length > 3 ? list.slice(0, 2) : list;
          for (const it of shown) {
            const size = typeof it.value === "number" && maxValue > 0 ? 8 + Math.round(Math.sqrt(Math.abs(it.value) / maxValue) * 10) : 12;
            const day = toDay(it.start);
            const b = h("button", { type: "button", class: "cal-mark shape-" + (it.shape || "dot") + (it.outline ? " outline" : "") + (it.id === el.focus ? " focus" : ""),
              tabindex: "-1", "data-item": it.id, title: (it.label || it.id) + " · " + fmtLong(day), "aria-label": (it.label || it.id) + ", " + fmtLong(day) });
            b.style.setProperty("--cal-color", markColor(it));
            b.style.setProperty("--cal-size", size + "px");
            b.addEventListener("click", () => send({ kind: "item", item: it.id, row: r.id, date: iso(day) }));
            cells[k].appendChild(b);
          }
          if (list.length > 3) {
            const more = h("button", { type: "button", class: "cal-more", tabindex: "-1", text: "+" + (list.length - 2),
              title: list.slice(2).map((i) => i.label || i.id).join("\n"), "aria-label": (list.length - 2) + " more on " + fmtLong(cols[k].from) });
            more.addEventListener("click", () => send({ kind: "cell", row: r.id, date: iso(cols[k].from) }));
            cells[k].appendChild(more);
          }
        });
        cells.forEach((td) => tr.appendChild(td));
        tb.appendChild(tr);
      }
      t.appendChild(tb);
      const hadFocus = wrap.contains(document.activeElement) && document.activeElement.dataset ? document.activeElement.dataset.item : null;
      wrap.replaceChildren(t);
      // month names stay visible next to the sticky columns while scrolling sideways
      requestAnimationFrame(() => {
        const name = t.querySelector("thead .cal-name"), sum = t.querySelector("thead .cal-sum");
        const w = (name ? name.offsetWidth : 0) + (sum ? sum.offsetWidth : 0);
        t.querySelectorAll(".cal-month-label").forEach((s) => { s.style.left = w + 8 + "px"; });
      });
      // one tab stop among the items: the focused one, else the first
      const focusables = Array.from(wrap.querySelectorAll(".cal-mark, .cal-span:not([aria-hidden]), .cal-more"));
      const stop = (hadFocus && focusables.find((b) => b.dataset.item === hadFocus)) || focusables[0];
      if (stop) { stop.tabIndex = 0; if (hadFocus) stop.focus({ preventScroll: true }); }
    }

    // arrows move between items: ←/→ along the row, ↑/↓ to the nearest item in the next row
    wrap.addEventListener("keydown", (ev) => {
      const cur = document.activeElement;
      if (!cur || !cur.matches || !cur.matches(".cal-mark, .cal-span, .cal-more")) return;
      const all = Array.from(wrap.querySelectorAll(".cal-mark, .cal-span:not([aria-hidden]), .cal-more"));
      const rowOf = (b) => b.closest("tr");
      const colIdx = (b) => +b.closest("td").dataset.col;
      let target = null;
      const sameRow = all.filter((b) => rowOf(b) === rowOf(cur));
      const i = sameRow.indexOf(cur);
      if (ev.key === "ArrowRight") target = sameRow[i + 1];
      else if (ev.key === "ArrowLeft") target = sameRow[i - 1];
      else if (ev.key === "Home") target = sameRow[0];
      else if (ev.key === "End") target = sameRow[sameRow.length - 1];
      else if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
        const trs = Array.from(wrap.querySelectorAll("tbody tr"));
        let ti = trs.indexOf(rowOf(cur));
        const step = ev.key === "ArrowDown" ? 1 : -1;
        for (ti += step; ti >= 0 && ti < trs.length && !target; ti += step) {
          const cand = all.filter((b) => rowOf(b) === trs[ti]);
          if (cand.length) target = cand.reduce((best, b) => (Math.abs(colIdx(b) - colIdx(cur)) < Math.abs(colIdx(best) - colIdx(cur)) ? b : best));
        }
      } else return;
      ev.preventDefault();
      if (target) { cur.tabIndex = -1; target.tabIndex = 0; target.focus(); }
    });

    draw();
    // scroll: as before this rerun, or to today the first time
    if (memo.scroll) { wrap.scrollTop = memo.scroll[0]; wrap.scrollLeft = memo.scroll[1]; }
    else requestAnimationFrame(() => {
      const t = wrap.querySelector("th.cal-day.today");
      const sticky = wrap.querySelector("thead th.cal-name");
      if (t) wrap.scrollLeft = Math.max(0, t.offsetLeft - (sticky ? sticky.offsetWidth : 0) - 3 * t.offsetWidth - (hasSummary ? wrap.querySelector("thead th.cal-sum").offsetWidth : 0));
    });
    wrap.addEventListener("scroll", () => { memo.scroll = [wrap.scrollTop, wrap.scrollLeft]; }, { passive: true });
    // focus: scroll to the item and highlight it, once per focus value
    if (focusItem && memo.focusToken !== el.focus) {
      memo.focusToken = el.focus;
      requestAnimationFrame(() => {
        const b = wrap.querySelector('[data-item="' + CSS.escape(el.focus) + '"]');
        if (b) { b.scrollIntoView({ block: "center", inline: "center", behavior: "auto" }); b.classList.add("pulse"); }
      });
    }
  }

  function isoWeek(day) {
    const d = new Date(day * DAY);
    const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
    t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
    const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
    return Math.ceil(((t - y0) / DAY + 1) / 7);
  }

  return { render };
})();
