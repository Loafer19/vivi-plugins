// Search, category filter and sorting for the plugin grid. ?cat=Music&q=lyrics are kept in the URL.
(() => {
  const grid = document.getElementById("grid"), q = document.getElementById("q"), sort = document.getElementById("sort");
  const cards = [...grid.children], buttons = [...document.querySelectorAll(".cats button")];
  const params = new URLSearchParams(location.search);
  let cat = params.get("cat") || "";
  q.value = params.get("q") || "";
  const SORTS = [...sort.options].map(o => o.value);
  sort.value = SORTS.includes(params.get("sort")) ? params.get("sort") : "name";
  function apply() {
    const words = q.value.toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0;
    for (const c of cards) {
      const ok = (!cat || c.dataset.cats.split("|").includes(cat)) && words.every(w => c.dataset.text.includes(w));
      c.hidden = !ok; shown += ok;
    }
    const name = (a, b) => a.dataset.name.localeCompare(b.dataset.name);
    const time = c => Date.parse(c.dataset.date) || 0; // ISO timestamps; undated cards go last
    const key = sort.value, by = {
      name,
      date: (a, b) => time(b) - time(a) || name(a, b),
    }[key] || name;
    cards.slice().sort(by).forEach(c => grid.appendChild(c));
    buttons.forEach(b => b.classList.toggle("on", b.dataset.cat === cat));
    document.getElementById("empty").hidden = shown > 0;
    const p = new URLSearchParams();
    if (cat) p.set("cat", cat); if (q.value) p.set("q", q.value); if (key !== "name") p.set("sort", key);
    history.replaceState(null, "", p.toString() ? "?" + p : location.pathname);
  }
  buttons.forEach(b => b.addEventListener("click", () => { cat = b.dataset.cat; apply(); }));
  q.addEventListener("input", apply); sort.addEventListener("change", apply);
  addEventListener("popstate", () => { const v = new URLSearchParams(location.search).get("sort"); sort.value = SORTS.includes(v) ? v : "name"; apply(); });
  apply();
})();
