// A small label: st.customElement("badge", {"text": "beta", "tone": "primary"}). Display only.
StreamlitD.registerElement("badge", {
  render(box, el, api) {
    const span = document.createElement("span");
    box.appendChild(span);
    const draw = (e) => {
      span.className = "badge badge-" + ((e.props && e.props.tone) || "primary");
      span.innerHTML = api.markdown((e.props && e.props.text) || "");
    };
    draw(el);
    return { update: draw };
  },
});
