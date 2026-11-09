/* streamlitd UI kit: themed replacements for native browser pop-up controls.
   - popups: rendered into a body-level portal (#stPopups, position: fixed) so they are never
     clipped by overflow on dataframes, expanders, dialogs, the sidebar or the settings panel.
   - combobox / multiCombobox: searchable, keyboard- and screen-reader-friendly selects.
   - datePicker / timePicker / colorPicker.
   Everything is styled with the theme tokens, and per design in designs.css. */
window.StUI = (function () {
  "use strict";

  function h(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      const v = attrs[k];
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") e.className = v;
      else if (k === "text") e.textContent = v;
      else if (k === "html") e.innerHTML = v;
      else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
      else if (k === "style" && typeof v === "object") Object.assign(e.style, v);
      else e.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return e;
  }
  let uidN = 0;
  const uid = (p) => (p || "st-ui") + "-" + (++uidN);

  // ------------------------------------------------------------------ popups
  const stack = []; // open popups, innermost last
  function portal() {
    let p = document.getElementById("stPopups");
    if (!p) { p = h("div", { id: "stPopups" }); document.body.appendChild(p); }
    return p;
  }
  /** True if the node is inside an open popup (used by other "click outside" handlers). */
  function inPopup(node) { return !!(node && node.closest && node.closest(".st-popup")); }

  function closeFrom(i) {
    while (stack.length > i) {
      const p = stack.pop();
      p.pop.remove();
      if (p.onClose) try { p.onClose(); } catch (e) {}
    }
  }
  function closeAll() { closeFrom(0); }

  /** Open `content` in a popup anchored to `anchor`. Options: className, minWidth, nested (keep
   *  parent popups open), onClose, label/role for the popup element. Returns { pop, place, close }. */
  function openPopup(anchor, content, opts) {
    opts = opts || {};
    const parentIdx = opts.nested ? stack.findIndex((p) => p.pop.contains(anchor)) : -1;
    closeFrom(parentIdx + 1);
    const pop = h("div", { class: "st-popup " + (opts.className || ""), role: opts.role || null, "aria-label": opts.label || null,
      "aria-modal": opts.role === "dialog" ? "false" : null });
    pop.appendChild(content);
    portal().appendChild(pop);
    const place = () => {
      if (!anchor.isConnected) { closeFrom(stack.indexOf(entry)); return; }
      const m = 8, gap = 4;
      const r = anchor.getBoundingClientRect();
      const vw = document.documentElement.clientWidth, vh = window.innerHeight;
      pop.style.maxHeight = "";
      pop.style.minWidth = Math.min(vw - 2 * m, Math.max(r.width, opts.minWidth || 0)) + "px";
      pop.style.maxWidth = (vw - 2 * m) + "px";
      const natural = pop.scrollHeight;
      const below = vh - r.bottom - gap - m, above = r.top - gap - m;
      const down = below >= Math.min(natural, 260) || below >= above;
      const avail = Math.max(100, down ? below : above);
      pop.style.maxHeight = avail + "px";
      const ph = Math.min(natural, avail);
      pop.style.top = Math.max(m, down ? r.bottom + gap : r.top - gap - ph) + "px";
      const w = pop.offsetWidth;
      let left = opts.alignRight ? r.right - w : r.left;
      left = Math.min(left, vw - m - w);
      pop.style.left = Math.max(m, left) + "px";
    };
    const entry = { pop, anchor, onClose: opts.onClose, place };
    stack.push(entry);
    place();
    requestAnimationFrame(place);
    return { pop, place, close: () => { const i = stack.indexOf(entry); if (i >= 0) closeFrom(i); }, isOpen: () => stack.includes(entry) };
  }
  window.addEventListener("resize", () => stack.forEach((p) => p.place()));
  window.addEventListener("scroll", (ev) => {
    // scrolling inside a popup (its list) must not move it
    if (inPopup(ev.target)) return;
    stack.forEach((p) => p.place());
  }, true);
  document.addEventListener("pointerdown", (ev) => {
    if (!stack.length) return;
    for (let i = stack.length - 1; i >= 0; i--) {
      const p = stack[i];
      if (p.pop.contains(ev.target) || p.anchor.contains(ev.target)) { closeFrom(i + 1); return; }
    }
    closeAll();
  }, true);

  // ------------------------------------------------------------------ listbox (shared)
  /** A listbox rendered into a popup. items: [{label, hint, swatches, disabled, selected}] */
  function renderList(list, items, activeIdx, onPick, emptyText) {
    list.innerHTML = "";
    if (!items.length) {
      list.appendChild(h("div", { class: "st-noresults", text: emptyText || "No results" }));
      return;
    }
    items.forEach((it, i) => {
      const o = h("div", {
        class: "st-option" + (i === activeIdx ? " active" : "") + (it.disabled ? " disabled" : ""),
        role: "option", id: list.id + "-o" + i, "aria-selected": it.selected ? "true" : "false",
        "aria-disabled": it.disabled ? "true" : null, "data-value": String(it.value),
      },
      it.multi ? h("span", { class: "st-check", "aria-hidden": "true", text: it.selected ? "✓" : "" }) : null,
      it.swatches ? h("span", { class: "st-swatches", "aria-hidden": "true" }, it.swatches.map((c) => h("span", { style: { background: c } }))) : null,
      h("span", { class: "st-option-text" }, h("span", { class: "st-option-label", text: it.label }), it.hint ? h("span", { class: "st-option-hint", text: it.hint }) : null));
      o.addEventListener("mousedown", (ev) => ev.preventDefault()); // keep focus in the input
      o.addEventListener("click", () => { if (!it.disabled) onPick(i); });
      list.appendChild(o);
    });
    const a = list.children[activeIdx];
    if (a && a.scrollIntoView) a.scrollIntoView({ block: "nearest" });
  }
  const matches = (label, q) => !q || label.toLowerCase().includes(q.toLowerCase());

  // ------------------------------------------------------------------ combobox
  /** Searchable single select. o: { id, label (accessible name), options: [{label, hint, swatches}],
   *  value (index | null), placeholder, disabled, onChange(index), className } */
  function combobox(o) {
    let options = o.options || [];
    let index = o.value === undefined ? null : o.value;
    let popup = null, items = [], active = -1;
    const listId = uid("st-lb");
    const input = h("input", {
      class: "st-cb-input", id: o.id || null, role: "combobox", "aria-expanded": "false", "aria-controls": listId,
      "aria-autocomplete": "list", "aria-haspopup": "listbox", autocomplete: "off", spellcheck: "false",
      "aria-label": o.label || null, disabled: o.disabled || null, "data-testid": o.testid || null,
    });
    const chevron = h("span", { class: "st-cb-chevron", "aria-hidden": "true" });
    const el = h("div", { class: "st-combobox st-select" + (o.className ? " " + o.className : "") + (o.disabled ? " disabled" : "") }, input, chevron);
    const list = h("div", { class: "st-listbox", role: "listbox", id: listId, "aria-label": o.label || null });
    const show = () => {
      input.value = index === null || index === undefined || !options[index] ? "" : options[index].label;
      input.placeholder = o.placeholder || "Choose an option";
    };
    const refresh = (q) => {
      items = options.map((op, i) => ({ ...op, value: i, selected: i === index })).filter((it) => matches(it.label, q));
      if (active >= items.length) active = items.length - 1;
      renderList(list, items, active, pick);
      input.setAttribute("aria-activedescendant", active >= 0 && items.length ? listId + "-o" + active : "");
      if (popup) popup.place();
    };
    const openList = () => {
      if (popup && popup.isOpen()) return;
      active = Math.max(0, options.findIndex((_, i) => i === index));
      popup = openPopup(el, list, { className: "st-popup-list", nested: inPopup(el), onClose: () => { popup = null; input.setAttribute("aria-expanded", "false"); input.removeAttribute("aria-activedescendant"); show(); } });
      input.setAttribute("aria-expanded", "true");
      // like Streamlit: the field is cleared for typing, the current value shows as placeholder
      const cur = options[index];
      input.value = "";
      if (cur) input.placeholder = cur.label;
      refresh("");
    };
    const closeList = () => { if (popup) popup.close(); };
    const pick = (i) => {
      const it = items[i];
      if (!it) return;
      index = it.value;
      closeList();
      show();
      if (o.onChange) o.onChange(index);
    };
    const move = (d) => {
      if (!popup) { openList(); return; }
      if (!items.length) return;
      active = d === "home" ? 0 : d === "end" ? items.length - 1 : Math.max(0, Math.min(items.length - 1, active + d));
      refresh(input.value);
    };
    input.addEventListener("mousedown", () => { if (popup) closeList(); else setTimeout(openList, 0); });
    chevron.addEventListener("mousedown", (ev) => { ev.preventDefault(); if (o.disabled) return; if (popup) closeList(); else { input.focus(); openList(); } });
    input.addEventListener("input", () => { if (!popup) openList(); active = 0; refresh(input.value); });
    input.addEventListener("keydown", (ev) => {
      switch (ev.key) {
        case "ArrowDown": ev.preventDefault(); move(ev.altKey && !popup ? 0 : 1); break;
        case "ArrowUp": ev.preventDefault(); move(-1); break;
        case "PageDown": if (popup) { ev.preventDefault(); move(8); } break;
        case "PageUp": if (popup) { ev.preventDefault(); move(-8); } break;
        case "Home": if (popup) { ev.preventDefault(); move("home"); } break;
        case "End": if (popup) { ev.preventDefault(); move("end"); } break;
        case "Enter": if (popup) { ev.preventDefault(); pick(active); } else { ev.preventDefault(); openList(); } break;
        case "Escape": if (popup) { ev.preventDefault(); ev.stopPropagation(); closeList(); } break;
        case "Tab": if (popup) { if (input.value) pick(active); else closeList(); } break;
      }
    });
    input.addEventListener("blur", () => setTimeout(() => { if (popup && !popup.pop.contains(document.activeElement)) closeList(); }, 120));
    show();
    return {
      el, input,
      setValue(i) { index = i; if (!popup) show(); },
      setOptions(opts) { options = opts; if (!popup) show(); else refresh(""); },
      value: () => index,
    };
  }

  // ------------------------------------------------------------------ multi combobox
  /** Searchable multi select with chips. o: { label, options: [{label}], value: [indices],
   *  placeholder, disabled, max, onChange(indices) } */
  function multiCombobox(o) {
    let options = o.options || [];
    let value = (o.value || []).slice();
    let popup = null, items = [], active = 0;
    const listId = uid("st-lb");
    const chips = h("span", { class: "st-chips" });
    const input = h("input", {
      class: "st-cb-input", id: o.id || null, role: "combobox", "aria-expanded": "false", "aria-controls": listId, "aria-autocomplete": "list",
      "aria-haspopup": "listbox", autocomplete: "off", spellcheck: "false", "aria-label": o.label || null, disabled: o.disabled || null,
    });
    const clear = h("button", { type: "button", class: "st-cb-clear", title: "Clear all", "aria-label": "Clear all", text: "×" });
    const chevron = h("span", { class: "st-cb-chevron", "aria-hidden": "true" });
    const el = h("div", { class: "st-combobox st-multi multiselect" + (o.disabled ? " disabled" : "") }, chips, input, clear, chevron);
    const list = h("div", { class: "st-listbox", role: "listbox", id: listId, "aria-multiselectable": "true", "aria-label": o.label || null });
    const full = () => o.max > 0 && value.length >= o.max;
    const emit = () => { if (o.onChange) o.onChange(value.slice()); };
    const drawChips = () => {
      chips.innerHTML = "";
      value.forEach((i) => {
        const x = h("button", { type: "button", title: "Remove", text: "×", "aria-label": "Remove " + options[i].label });
        x.addEventListener("mousedown", (ev) => ev.preventDefault());
        x.addEventListener("click", (ev) => { ev.stopPropagation(); value = value.filter((v) => v !== i); drawChips(); refresh(); emit(); });
        chips.appendChild(h("span", { class: "chip" }, h("span", { text: options[i].label }), x));
      });
      clear.hidden = !value.length || o.disabled;
      input.placeholder = value.length ? "" : (o.placeholder || "Choose options");
      if (popup) popup.place();
    };
    const refresh = () => {
      const q = input.value;
      items = options.map((op, i) => ({ label: op.label, value: i, multi: true, selected: value.includes(i), disabled: !value.includes(i) && full() }))
        .filter((it) => matches(it.label, q));
      if (active >= items.length) active = Math.max(0, items.length - 1);
      renderList(list, items, active, toggle, "No results");
      if (full()) list.insertBefore(h("div", { class: "st-noresults", text: "Maximum reached (" + o.max + ")" }), list.firstChild);
      input.setAttribute("aria-activedescendant", items.length ? listId + "-o" + active : "");
      if (popup) popup.place();
    };
    const openList = () => {
      if (popup && popup.isOpen()) return;
      popup = openPopup(el, list, { className: "st-popup-list", nested: inPopup(el), onClose: () => { popup = null; input.setAttribute("aria-expanded", "false"); input.value = ""; } });
      input.setAttribute("aria-expanded", "true");
      active = 0;
      refresh();
    };
    const toggle = (i) => {
      const it = items[i];
      if (!it || it.disabled) return;
      active = i;
      value = value.includes(it.value) ? value.filter((v) => v !== it.value) : value.concat([it.value]);
      input.value = "";
      drawChips();
      refresh();
      emit();
    };
    el.addEventListener("mousedown", (ev) => {
      if (o.disabled || ev.target.closest("button")) return;
      ev.preventDefault();
      input.focus();
      if (popup) popup.close(); else openList();
    });
    clear.addEventListener("mousedown", (ev) => ev.preventDefault());
    clear.addEventListener("click", (ev) => { ev.stopPropagation(); value = []; drawChips(); refresh(); emit(); });
    input.addEventListener("input", () => { if (!popup) openList(); active = 0; refresh(); });
    input.addEventListener("keydown", (ev) => {
      switch (ev.key) {
        case "ArrowDown": ev.preventDefault(); if (!popup) openList(); else { active = Math.min(items.length - 1, active + 1); refresh(); } break;
        case "ArrowUp": ev.preventDefault(); if (popup) { active = Math.max(0, active - 1); refresh(); } break;
        case "Home": if (popup) { ev.preventDefault(); active = 0; refresh(); } break;
        case "End": if (popup) { ev.preventDefault(); active = items.length - 1; refresh(); } break;
        case "Enter": ev.preventDefault(); if (popup) toggle(active); else openList(); break;
        case "Escape": if (popup) { ev.preventDefault(); ev.stopPropagation(); popup.close(); } break;
        case "Backspace": if (!input.value && value.length) { value = value.slice(0, -1); drawChips(); refresh(); emit(); } break;
        case "Tab": if (popup) popup.close(); break;
      }
    });
    input.addEventListener("blur", () => setTimeout(() => { if (popup && !el.contains(document.activeElement)) popup.close(); }, 120));
    drawChips();
    return { el, input, setValue(v) { value = (v || []).slice(); drawChips(); if (popup) refresh(); }, value: () => value.slice() };
  }

  // ------------------------------------------------------------------ date picker
  const pad = (n) => String(n).padStart(2, "0");
  const iso = (d) => d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
  function parseIso(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || "");
    if (!m) return null;
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    return d.getMonth() === +m[2] - 1 ? d : null;
  }
  function firstDayOfWeek() {
    try {
      const loc = new Intl.Locale(navigator.language || "en");
      const wi = loc.getWeekInfo ? loc.getWeekInfo() : loc.weekInfo;
      if (wi && wi.firstDay) return wi.firstDay % 7; // 1 = Monday ... 7 = Sunday → 0..6 (0 = Sunday)
    } catch (e) {}
    return 1;
  }
  const monthNames = () => Array.from({ length: 12 }, (_, i) => new Date(2000, i, 1).toLocaleString(undefined, { month: "long" }));

  /** o: { id, label, value 'YYYY-MM-DD', min, max, disabled, onChange(str) } */
  function datePicker(o) {
    let value = o.value || "";
    const minD = parseIso(o.min), maxD = parseIso(o.max);
    const input = h("input", { class: "st-input st-date-input", id: o.id || null, type: "text", inputmode: "numeric", placeholder: "YYYY-MM-DD",
      autocomplete: "off", disabled: o.disabled || null, "aria-haspopup": "dialog", "aria-expanded": "false" });
    const btn = h("button", { type: "button", class: "st-picker-btn", "aria-label": "Open calendar", title: "Open calendar", disabled: o.disabled || null, text: "📅" });
    const el = h("div", { class: "st-picker st-date" + (o.disabled ? " disabled" : "") }, input, btn);
    let popup = null, view = null, focus = null;
    const inRange = (d) => (!minD || d >= minD) && (!maxD || d <= maxD);
    const commit = (s) => { value = s; input.value = s; if (o.onChange) o.onChange(s); };
    const fdw = firstDayOfWeek();
    const names = monthNames();

    function build() {
      const wrap = h("div", { class: "st-calendar" });
      const y = view.getFullYear(), m = view.getMonth();
      const years = [];
      const y0 = minD ? minD.getFullYear() : Math.min(y, new Date().getFullYear()) - 100;
      const y1 = maxD ? maxD.getFullYear() : Math.max(y, new Date().getFullYear()) + 20;
      for (let yy = y0; yy <= y1; yy++) years.push({ label: String(yy) });
      const monthCb = combobox({ label: "Month", options: names.map((n) => ({ label: n })), value: m, onChange: (i) => { view = new Date(y, i, 1); clampFocus(); rerender(); } });
      const yearCb = combobox({ label: "Year", options: years, value: y - y0, onChange: (i) => { view = new Date(y0 + i, m, 1); clampFocus(); rerender(); } });
      monthCb.el.classList.add("st-cal-month");
      yearCb.el.classList.add("st-cal-year");
      const prev = h("button", { type: "button", class: "st-cal-nav", "aria-label": "Previous month", text: "‹" });
      const next = h("button", { type: "button", class: "st-cal-nav", "aria-label": "Next month", text: "›" });
      prev.addEventListener("click", () => { view = new Date(y, m - 1, 1); clampFocus(); rerender(); });
      next.addEventListener("click", () => { view = new Date(y, m + 1, 1); clampFocus(); rerender(); });
      wrap.appendChild(h("div", { class: "st-cal-head" }, prev, monthCb.el, yearCb.el, next));
      const grid = h("div", { class: "st-cal-grid", role: "grid", "aria-label": names[m] + " " + y });
      const head = h("div", { class: "st-cal-row", role: "row" });
      for (let i = 0; i < 7; i++) {
        const wd = new Date(2024, 0, 7 + ((fdw + i) % 7)); // 2024-01-07 is a Sunday
        head.appendChild(h("span", { class: "st-cal-wd", role: "columnheader", text: wd.toLocaleString(undefined, { weekday: "short" }).slice(0, 2) }));
      }
      grid.appendChild(head);
      const start = new Date(y, m, 1);
      start.setDate(1 - ((start.getDay() - fdw + 7) % 7));
      const today = iso(new Date());
      for (let r = 0; r < 6; r++) {
        const row = h("div", { class: "st-cal-row", role: "row" });
        for (let c = 0; c < 7; c++) {
          const d = new Date(start.getFullYear(), start.getMonth(), start.getDate() + r * 7 + c);
          const s = iso(d);
          const ok = inRange(d);
          const b = h("button", {
            type: "button", role: "gridcell", class: "st-cal-day" + (d.getMonth() !== m ? " other" : "") + (s === today ? " today" : "") + (s === value ? " selected" : ""),
            "aria-selected": s === value ? "true" : "false", "aria-label": d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }),
            disabled: ok ? null : true, tabindex: s === iso(focus) ? "0" : "-1", "data-date": s, text: String(d.getDate()),
          });
          b.addEventListener("click", () => { commit(s); close(); input.focus(); });
          row.appendChild(b);
        }
        grid.appendChild(row);
      }
      grid.addEventListener("keydown", onGridKey);
      wrap.appendChild(grid);
      return wrap;
    }
    function clampFocus() {
      const y = view.getFullYear(), m = view.getMonth();
      const day = Math.min(focus.getDate(), new Date(y, m + 1, 0).getDate());
      focus = new Date(y, m, day);
    }
    function rerender(keepFocus) {
      if (!popup) return;
      const content = build();
      popup.pop.innerHTML = "";
      popup.pop.appendChild(content);
      popup.place();
      if (keepFocus) {
        const b = popup.pop.querySelector('[data-date="' + iso(focus) + '"]');
        if (b) b.focus();
      }
    }
    function onGridKey(ev) {
      const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[ev.key];
      let d = null;
      if (step) d = new Date(focus.getFullYear(), focus.getMonth(), focus.getDate() + step);
      else if (ev.key === "PageUp") d = new Date(focus.getFullYear(), focus.getMonth() - 1, focus.getDate());
      else if (ev.key === "PageDown") d = new Date(focus.getFullYear(), focus.getMonth() + 1, focus.getDate());
      else if (ev.key === "Home") d = new Date(focus.getFullYear(), focus.getMonth(), focus.getDate() - ((focus.getDay() - fdw + 7) % 7));
      else if (ev.key === "End") d = new Date(focus.getFullYear(), focus.getMonth(), focus.getDate() + 6 - ((focus.getDay() - fdw + 7) % 7));
      else if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); close(); input.focus(); return; }
      if (!d) return;
      ev.preventDefault();
      focus = d;
      view = new Date(d.getFullYear(), d.getMonth(), 1);
      rerender(true);
    }
    function open() {
      if (popup) return;
      const cur = parseIso(value) || new Date();
      focus = inRange(cur) ? cur : (minD && cur < minD ? minD : maxD || cur);
      view = new Date(focus.getFullYear(), focus.getMonth(), 1);
      popup = openPopup(el, h("div"), { className: "st-popup-calendar", role: "dialog", label: "Choose date",
        onClose: () => { popup = null; input.setAttribute("aria-expanded", "false"); } });
      input.setAttribute("aria-expanded", "true");
      rerender(false);
    }
    function close() { if (popup) popup.close(); }
    const tryCommitTyped = () => {
      const d = parseIso(input.value.trim());
      if (d && inRange(d)) { if (iso(d) !== value) commit(iso(d)); else input.value = value; }
      else input.value = value;
    };
    btn.addEventListener("click", () => { if (popup) close(); else { open(); const b = popup && popup.pop.querySelector('.st-cal-day[tabindex="0"]'); if (b) b.focus(); } });
    input.addEventListener("click", () => { if (!popup) open(); });
    input.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter") { ev.preventDefault(); tryCommitTyped(); close(); }
      else if (ev.key === "ArrowDown" || (ev.key === "ArrowDown" && ev.altKey)) { ev.preventDefault(); open(); const b = popup.pop.querySelector('.st-cal-day[tabindex="0"]'); if (b) b.focus(); }
      else if (ev.key === "Escape" && popup) { ev.preventDefault(); ev.stopPropagation(); close(); }
    });
    input.addEventListener("blur", () => setTimeout(() => { if (!popup || !popup.pop.contains(document.activeElement)) tryCommitTyped(); }, 150));
    input.value = value;
    return { el, input, setValue(v) { value = v || ""; if (document.activeElement !== input) input.value = value; } };
  }

  // ------------------------------------------------------------------ time picker
  /** o: { id, value 'HH:MM', step (seconds), disabled, onChange(str) } */
  function timePicker(o) {
    let value = (o.value || "").slice(0, 5);
    const step = Math.max(60, o.step || 900);
    const input = h("input", { class: "st-input st-time-input", id: o.id || null, type: "text", inputmode: "numeric", placeholder: "HH:MM",
      autocomplete: "off", role: "combobox", "aria-expanded": "false", "aria-autocomplete": "list", disabled: o.disabled || null });
    const listId = uid("st-lb");
    input.setAttribute("aria-controls", listId);
    const btn = h("button", { type: "button", class: "st-picker-btn", "aria-label": "Choose time", title: "Choose time", disabled: o.disabled || null, text: "🕒" });
    const el = h("div", { class: "st-picker st-time" + (o.disabled ? " disabled" : "") }, input, btn);
    const all = [];
    for (let s = 0; s < 86400; s += step) all.push(pad(Math.floor(s / 3600)) + ":" + pad(Math.floor((s % 3600) / 60)));
    const list = h("div", { class: "st-listbox st-timelist", role: "listbox", id: listId, "aria-label": "Times" });
    let popup = null, items = [], active = 0;
    const valid = (s) => /^([01]\d|2[0-3]):[0-5]\d$/.test(s);
    const commit = (s) => { if (s !== value) { value = s; if (o.onChange) o.onChange(s); } input.value = value; };
    const refresh = (q) => {
      items = all.filter((t) => !q || t.startsWith(q)).map((t) => ({ label: t, value: t, selected: t === value }));
      if (active >= items.length) active = Math.max(0, items.length - 1);
      renderList(list, items, active, pick, "No matching time");
      input.setAttribute("aria-activedescendant", items.length ? listId + "-o" + active : "");
      if (popup) popup.place();
    };
    const pick = (i) => { const it = items[i]; if (!it) return; commit(it.value); if (popup) popup.close(); };
    const open = () => {
      if (popup) return;
      popup = openPopup(el, list, { className: "st-popup-list", onClose: () => { popup = null; input.setAttribute("aria-expanded", "false"); } });
      input.setAttribute("aria-expanded", "true");
      active = Math.max(0, all.findIndex((t) => t >= (value || "00:00")));
      refresh("");
    };
    btn.addEventListener("click", () => { if (popup) popup.close(); else { input.focus(); open(); } });
    input.addEventListener("click", () => open());
    input.addEventListener("input", () => { if (!popup) open(); active = 0; refresh(input.value); });
    input.addEventListener("keydown", (ev) => {
      switch (ev.key) {
        case "ArrowDown": ev.preventDefault(); if (!popup) open(); else { active = Math.min(items.length - 1, active + 1); refresh(input.value === value ? "" : input.value); } break;
        case "ArrowUp": ev.preventDefault(); if (popup) { active = Math.max(0, active - 1); refresh(input.value === value ? "" : input.value); } break;
        case "Enter":
          ev.preventDefault();
          if (valid(input.value) && (!popup || input.value.length === 5)) { commit(input.value); if (popup) popup.close(); }
          else if (popup) pick(active);
          break;
        case "Escape": if (popup) { ev.preventDefault(); ev.stopPropagation(); popup.close(); input.value = value; } break;
        case "Tab": if (popup) popup.close(); break;
      }
    });
    input.addEventListener("blur", () => setTimeout(() => {
      if (popup && popup.pop.contains(document.activeElement)) return;
      if (popup) popup.close();
      if (valid(input.value)) commit(input.value); else input.value = value;
    }, 150));
    input.value = value;
    return { el, input, setValue(v) { value = (v || "").slice(0, 5); if (document.activeElement !== input) input.value = value; } };
  }

  // ------------------------------------------------------------------ color picker
  function hexToHsv(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
    const n = m ? parseInt(m[1], 16) : 0;
    const r = ((n >> 16) & 255) / 255, g = ((n >> 8) & 255) / 255, b = (n & 255) / 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let hh = 0;
    if (d) hh = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return { h: (hh * 60 + 360) % 360, s: max ? d / max : 0, v: max };
  }
  function hsvToHex(hh, s, v) {
    const f = (n) => { const k = (n + hh / 60) % 6; return v - v * s * Math.max(0, Math.min(k, 4 - k, 1)); };
    return "#" + [f(5), f(3), f(1)].map((x) => pad(Math.round(x * 255).toString(16))).join("");
  }
  /** o: { id, label, value '#rrggbb', disabled, onChange(hex), swatches() → [hex] } */
  function colorPicker(o) {
    let value = (o.value || "#000000").toLowerCase();
    const hexId = uid("st-hex");
    const sw = h("button", { type: "button", class: "st-color-swatch", id: o.id || null, "aria-haspopup": "dialog", "aria-expanded": "false",
      "aria-describedby": hexId, disabled: o.disabled || null, style: { background: value } });
    const txt = h("span", { class: "st-color-hex", id: hexId, text: value });
    const el = h("div", { class: "color-wrap st-color" + (o.disabled ? " disabled" : "") }, sw, txt);
    let popup = null, hsv = hexToHsv(value), draft = value;
    const setDraft = (hex, from) => {
      draft = hex.toLowerCase();
      sw.style.background = draft;
      txt.textContent = draft;
      if (from !== "hsv") hsv = hexToHsv(draft);
      if (popup) paint(from);
    };
    let area, knob, hue, hex;
    function paint(from) {
      area.style.background = "linear-gradient(to top, #000, transparent), linear-gradient(to right, #fff, hsl(" + hsv.h + ", 100%, 50%))";
      knob.style.left = hsv.s * 100 + "%";
      knob.style.top = (1 - hsv.v) * 100 + "%";
      knob.style.background = draft;
      if (from !== "hue") hue.value = String(Math.round(hsv.h));
      if (from !== "hex") hex.value = draft;
      area.setAttribute("aria-valuetext", "saturation " + Math.round(hsv.s * 100) + "%, brightness " + Math.round(hsv.v * 100) + "%");
    }
    function open() {
      const box = h("div", { class: "st-colorpop" });
      area = h("div", { class: "st-color-area", tabindex: "0", role: "slider", "aria-label": "Saturation and brightness" });
      knob = h("span", { class: "st-color-knob" });
      area.appendChild(knob);
      hue = h("input", { type: "range", class: "st-color-hue", min: 0, max: 359, "aria-label": "Hue" });
      hex = h("input", { type: "text", class: "st-input st-color-hexinput", maxlength: 7, "aria-label": "Hex color", spellcheck: "false" });
      const swatches = h("div", { class: "st-color-swatches" });
      const colors = (o.swatches ? o.swatches() : []).filter((c) => /^#[0-9a-f]{6}$/i.test(c));
      Array.from(new Set(colors.map((c) => c.toLowerCase()))).slice(0, 14).forEach((c) => {
        const b = h("button", { type: "button", class: "st-color-chip", title: c, "aria-label": "Use " + c, style: { background: c } });
        b.addEventListener("click", () => setDraft(c));
        swatches.appendChild(b);
      });
      box.append(area, hue, hex, swatches);
      const drag = (ev) => {
        const r = area.getBoundingClientRect();
        hsv.s = Math.min(1, Math.max(0, (ev.clientX - r.left) / r.width));
        hsv.v = 1 - Math.min(1, Math.max(0, (ev.clientY - r.top) / r.height));
        setDraft(hsvToHex(hsv.h, hsv.s, hsv.v), "hsv");
      };
      area.addEventListener("pointerdown", (ev) => { area.setPointerCapture(ev.pointerId); drag(ev); area.focus(); });
      area.addEventListener("pointermove", (ev) => { if (area.hasPointerCapture(ev.pointerId)) drag(ev); });
      area.addEventListener("keydown", (ev) => {
        const d = ev.shiftKey ? 0.1 : 0.02;
        const k = { ArrowLeft: ["s", -d], ArrowRight: ["s", d], ArrowUp: ["v", d], ArrowDown: ["v", -d] }[ev.key];
        if (!k) return;
        ev.preventDefault();
        hsv[k[0]] = Math.min(1, Math.max(0, hsv[k[0]] + k[1]));
        setDraft(hsvToHex(hsv.h, hsv.s, hsv.v), "hsv");
      });
      hue.addEventListener("input", () => { hsv.h = +hue.value; setDraft(hsvToHex(hsv.h, hsv.s, hsv.v), "hue"); });
      hex.addEventListener("input", () => { if (/^#[0-9a-f]{6}$/i.test(hex.value)) setDraft(hex.value, "hex"); });
      hex.addEventListener("keydown", (ev) => { if (ev.key === "Enter") { ev.preventDefault(); close(); sw.focus(); } });
      box.addEventListener("keydown", (ev) => { if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); setDraft(value); close(); sw.focus(); } });
      popup = openPopup(sw, box, { className: "st-popup-color", role: "dialog", label: "Choose color", minWidth: 220,
        onClose: () => {
          popup = null;
          sw.setAttribute("aria-expanded", "false");
          if (draft !== value) { value = draft; if (o.onChange) o.onChange(value); }
        } });
      sw.setAttribute("aria-expanded", "true");
      paint();
    }
    function close() { if (popup) popup.close(); }
    sw.addEventListener("click", () => { if (popup) close(); else open(); });
    return {
      el,
      setValue(v) { value = (v || "#000000").toLowerCase(); if (!popup) setDraft(value); },
      value: () => value,
    };
  }

  return { h, openPopup, closeAll, inPopup, combobox, multiCombobox, datePicker, timePicker, colorPicker };
})();
