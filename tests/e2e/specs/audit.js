// In-page UI audit: finds clipped/overflowing elements, viewport escapes, covered popups and
// low-contrast text. Used by ui-audit.spec.js; run with `await audit(page, "state name")`.

/** Runs inside the browser. Returns [{type, where, detail}]. */
function inPageAudit() {
  const out = [];
  const vw = document.documentElement.clientWidth, vh = window.innerHeight;
  const visible = (el) => {
    if (!(el instanceof Element)) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    for (let a = el; a; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.display === "none" || cs.visibility === "hidden" || +cs.opacity === 0) return false;
      if (a.hidden) return false;
    }
    return true;
  };
  const describe = (el) => {
    const parts = [];
    for (let a = el, i = 0; a && a !== document.body && i < 4; a = a.parentElement, i++) {
      let s = a.tagName.toLowerCase();
      if (a.id) { s += "#" + a.id; parts.unshift(s); break; }
      const tid = a.getAttribute("data-testid");
      if (tid) s += '[data-testid="' + tid + '"]';
      const cls = [...a.classList].filter((c) => !/^(active|stale|selected)$/.test(c)).slice(0, 2);
      if (cls.length) s += "." + cls.join(".");
      parts.unshift(s);
    }
    const label = (el.getAttribute("aria-label") || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 40);
    return parts.join(" > ") + (label ? ' "' + label + '"' : "");
  };
  // third-party renderers manage their own clipping
  const SKIP = ".vega-wrap, .plotly-wrap, .map-wrap, iframe, svg, canvas, .katex, .st-cb-input, input, textarea, .code-block pre *, .json-view *, .df-wrap table *";
  const roots = [...document.querySelectorAll("#stSettingsPanel, .st-popup, .dialog-box, #stSidebar, #stRoot-0, #stBottom, #st-header")].filter(visible);

  // 1. horizontal page scroll
  if (document.documentElement.scrollWidth > vw + 1)
    out.push({ type: "page-hscroll", where: "document", detail: "scrollWidth " + document.documentElement.scrollWidth + " > " + vw });

  // 2. clipping by an ancestor with overflow hidden/clip, and text overflowing its own box
  const textish = ".st-btn, .choice, .tab-btn, .chip, .badge, .design-card, .style-swatch, .dc-label, .st-option-label, .widget-label, .metric-label, .metric-value, #stNav a, summary, .dialog-head h3, .seg button, .st-cal-day, .st-cal-nav, .page-link";
  for (const root of roots) {
    for (const el of root.querySelectorAll("*")) {
      if (el.closest(SKIP) || !visible(el)) continue;
      const r = el.getBoundingClientRect();
      for (let a = el.parentElement; a && a !== document.documentElement; a = a.parentElement) {
        const cs = getComputedStyle(a);
        const ox = cs.overflowX, oy = cs.overflowY;
        const clipX = ox === "hidden" || ox === "clip", clipY = oy === "hidden" || oy === "clip";
        if (!clipX && !clipY && ox === "visible" && oy === "visible") continue;
        const ar = a.getBoundingClientRect();
        const bl = parseFloat(cs.borderLeftWidth), br = parseFloat(cs.borderRightWidth), bt = parseFloat(cs.borderTopWidth), bb = parseFloat(cs.borderBottomWidth);
        if (clipX && (r.left < ar.left + bl - 1 || r.right > ar.right - br + 1))
          out.push({ type: "clipped-x", where: describe(el), detail: "cut by " + describe(a) + ` (${Math.round(r.left)}..${Math.round(r.right)} vs ${Math.round(ar.left)}..${Math.round(ar.right)})` });
        if (clipY && (r.top < ar.top + bt - 1 || r.bottom > ar.bottom - bb + 1) && a.scrollHeight <= a.clientHeight + 1)
          out.push({ type: "clipped-y", where: describe(el), detail: "cut by " + describe(a) });
        break; // only the nearest overflow ancestor matters
      }
      if (el.matches(textish)) {
        const cs = getComputedStyle(el);
        if (cs.overflowX === "visible" && el.scrollWidth > el.clientWidth + 2 && el.clientWidth > 0)
          out.push({ type: "text-overflow", where: describe(el), detail: `content ${el.scrollWidth}px in ${el.clientWidth}px` });
      }
    }
  }

  // 2b. values cut off inside input fields (comboboxes, date/time, number) while not being edited
  for (const root of roots) {
    for (const inp of root.querySelectorAll(".st-cb-input, .st-input, .number-wrap input")) {
      if (!visible(inp) || inp === document.activeElement || !inp.value) continue;
      if (inp.closest(".vega-wrap, .plotly-wrap, .map-wrap") || inp.matches("textarea")) continue;
      if (inp.scrollWidth > inp.clientWidth + 1)
        out.push({ type: "truncated-value", where: describe(inp) + ' "' + inp.value.slice(0, 30) + '"', detail: `value needs ${inp.scrollWidth}px, has ${inp.clientWidth}px` });
    }
  }

  // 3. floating layers must stay inside the viewport
  for (const el of document.querySelectorAll("#stSettingsPanel, .st-popup, .dialog-box, .popover-panel, .toast")) {
    if (!visible(el)) continue;
    const r = el.getBoundingClientRect();
    const scrollsWithPage = el.closest(".dialog-overlay"); // the dialog overlay scrolls vertically itself
    if (r.left < -1 || r.right > vw + 1 || r.top < -1 || (!scrollsWithPage && r.bottom > vh + 1))
      out.push({ type: "outside-viewport", where: describe(el), detail: `${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}x${Math.round(r.height)} in ${vw}x${vh}` });
    if (el.scrollWidth > el.clientWidth + 2 && getComputedStyle(el).overflowX !== "visible")
      out.push({ type: "layer-hscroll", where: describe(el), detail: `scrollWidth ${el.scrollWidth} > ${el.clientWidth}` });
  }

  // 4. covered: header buttons and popups must be on top where they are
  const hit = (el) => {
    const r = el.getBoundingClientRect();
    const x = Math.min(vw - 1, Math.max(0, r.left + r.width / 2)), y = Math.min(vh - 1, Math.max(0, r.top + Math.min(r.height / 2, 12)));
    const top = document.elementFromPoint(x, y);
    return !top || el.contains(top) || top.contains(el) || (top.closest && top.closest("#stPopups") && el.closest("#stPopups"));
  };
  for (const el of document.querySelectorAll("#stSettings, #stRerun, .st-popup, #stSettingsPanel")) {
    if (!visible(el)) continue;
    if (document.querySelector(".dialog-overlay") && el.closest("#st-header")) continue; // modal dialogs cover the page on purpose
    if (document.querySelector(".st-popup") && !el.closest("#stPopups") && el.matches("#stSettings, #stRerun")) continue;
    if (!hit(el)) out.push({ type: "covered", where: describe(el), detail: "another element is on top" });
  }

  // 5. contrast (WCAG): 4.5:1 for normal text, 3:1 for large text
  // any CSS color (rgb(), color(srgb ...) from color-mix(), oklab() during transitions, ...) -> [r, g, b, a]:
  // let the browser convert it by painting one canvas pixel
  const px = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  px.canvas.width = px.canvas.height = 1;
  const parse = (c) => {
    if (!c || c === "transparent") return [0, 0, 0, 0];
    px.clearRect(0, 0, 1, 1);
    px.fillStyle = "#000";
    px.fillStyle = c;
    px.fillRect(0, 0, 1, 1);
    const d = px.getImageData(0, 0, 1, 1).data;
    return [d[0], d[1], d[2], d[3] / 255];
  };
  const lum = ([r, g, b]) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
  const blend = (top, bottom) => { const a = top[3]; return [0, 1, 2].map((i) => top[i] * a + bottom[i] * (1 - a)).concat([1]); };
  const background = (el) => {
    const layers = [];
    for (let a = el; a; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.backgroundImage !== "none" || (cs.backdropFilter && cs.backdropFilter !== "none")) return null; // gradients/blur: unknown
      const c = parse(cs.backgroundColor);
      if (c[3] > 0) { layers.push(c); if (c[3] >= 0.999) break; }
      if (!a.parentElement) layers.push([255, 255, 255, 1]);
    }
    let col = layers.pop() || [255, 255, 255, 1];
    while (layers.length) col = blend(layers.pop(), col);
    return col;
  };
  const textSel = "label, p, span, a, button, summary, h1, h2, h3, li, td, th, .st-option-label, .metric-value, .metric-label, .alert, .markdown, .widget-label, .chip, .badge, .tab-btn, .seg button";
  const seen = new Set();
  for (const root of roots) {
    for (const el of root.querySelectorAll(textSel)) {
      if (el.closest(SKIP + ", .help, .metric-delta, .st-color-chip, .toast, .disabled, [disabled], [aria-disabled=true], .exception") || !visible(el)) continue;
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 1);
      if (!own) continue;
      const cs = getComputedStyle(el);
      const bg = background(el);
      if (!bg) continue;
      const fg = blend(parse(cs.color), bg);
      const l1 = lum(fg), l2 = lum(bg);
      const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
      const size = parseFloat(cs.fontSize), bold = +cs.fontWeight >= 700;
      const need = size >= 24 || (bold && size >= 18.66) ? 3 : 4.5;
      if (ratio < need) {
        const key = describe(el).replace(/".*"$/, "") + cs.color;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ type: "contrast", where: describe(el), detail: ratio.toFixed(2) + ":1 < " + need + ":1 (" + cs.color + " on rgb(" + bg.slice(0, 3).map(Math.round).join(",") + "))" });
      }
    }
  }
  // de-duplicate
  const uniq = new Map();
  for (const f of out) uniq.set(f.type + "|" + f.where, f);
  return [...uniq.values()];
}

/** Audit the page in its current state; returns findings tagged with `state`. */
async function audit(page, state) {
  const findings = await page.evaluate(inPageAudit);
  return findings.map((f) => Object.assign({ state }, f));
}

module.exports = { audit, inPageAudit };
