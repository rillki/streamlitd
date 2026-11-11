// A star-rating widget: st.customWidget!int("rating", label, default, props: {"max": 5}).
StreamlitD.registerElement("rating", {
  render(box, el, api) {
    box.appendChild(api.label());
    const row = document.createElement("div");
    row.className = "rating";
    row.setAttribute("role", "radiogroup");
    row.setAttribute("aria-label", el.label);
    box.appendChild(row);
    let stars = [];
    let value = el.value;

    function build() {
      const max = (el.props && el.props.max) || 5;
      row.replaceChildren();
      stars = [];
      for (let i = 1; i <= max; i++) {
        const b = document.createElement("button");
        b.type = "button";
        b.className = "rating-star";
        b.textContent = "★";
        b.setAttribute("role", "radio");
        b.setAttribute("aria-label", i + " of " + max);
        b.addEventListener("click", () => { value = i; draw(); api.setValue(i); });
        row.appendChild(b);
        stars.push(b);
      }
      draw();
    }
    function draw() {
      stars.forEach((b, i) => {
        b.classList.toggle("on", i < value);
        b.setAttribute("aria-checked", String(i + 1 === value));
        b.disabled = !!el.disabled;
      });
    }
    build();
    return {
      // new value or props from the server (the node and its focus stay)
      update(e) {
        const rebuild = JSON.stringify(e.props) !== JSON.stringify(el.props);
        el = e;
        value = e.value;
        if (rebuild) build(); else draw();
      },
    };
  },
});
