// Search, category filter and sorting for the plugin grid. ?cat=Music&q=lyrics are kept in the URL.
// Deprecated plugins (cards with data-dep) are only shown under the "Deprecated" filter (?cat=deprecated);
// every other view, search included, leaves them out and at most points to them.
(() => {
  const grid = document.getElementById("grid"), q = document.getElementById("q"), sort = document.getElementById("sort");
  const cards = [...grid.children], buttons = [...document.querySelectorAll(".cats button")];
  const tip = document.getElementById("deptip");
  const DEP = "deprecated";
  const params = new URLSearchParams(location.search);
  let cat = params.get("cat") || "";
  q.value = params.get("q") || "";
  const SORTS = [...sort.options].map(o => o.value);
  sort.value = SORTS.includes(params.get("sort")) ? params.get("sort") : "name";
  function apply() {
    const words = q.value.toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0, hiddenDep = 0;
    for (const c of cards) {
      const dep = "dep" in c.dataset;
      const text = words.every(w => c.dataset.text.includes(w));
      const inCat = cat === DEP ? dep : !dep && (!cat || c.dataset.cats.split("|").includes(cat));
      const ok = inCat && text;
      if (dep && !ok && cat !== DEP && words.length && text) hiddenDep++;
      c.hidden = !ok; shown += ok;
    }
    grid.classList.toggle("show-dep", cat === DEP);
    const name = (a, b) => a.dataset.name.localeCompare(b.dataset.name);
    const time = c => Date.parse(c.dataset.date) || 0; // ISO timestamps; undated cards go last
    const key = sort.value, by = {
      name,
      date: (a, b) => time(b) - time(a) || name(a, b),
    }[key] || name;
    cards.slice().sort(by).forEach(c => grid.appendChild(c));
    buttons.forEach(b => b.classList.toggle("on", b.dataset.cat === cat));
    document.getElementById("empty").hidden = shown > 0;
    if (tip) {
      tip.hidden = !hiddenDep;
      tip.innerHTML = hiddenDep ? `${hiddenDep} deprecated plugin${hiddenDep > 1 ? "s" : ""} also match${hiddenDep > 1 ? "" : "es"}. <a href="#" data-show-dep>Show deprecated</a>` : "";
    }
    const p = new URLSearchParams();
    if (cat) p.set("cat", cat); if (q.value) p.set("q", q.value); if (key !== "name") p.set("sort", key);
    const ds = new URLSearchParams(location.search).get("depstyle"); if (ds) p.set("depstyle", ds); // design preview only
    history.replaceState(null, "", p.toString() ? "?" + p : location.pathname);
  }
  buttons.forEach(b => b.addEventListener("click", () => { cat = b.dataset.cat; apply(); }));
  tip && tip.addEventListener("click", ev => { if (ev.target.matches("[data-show-dep]")) { ev.preventDefault(); cat = DEP; apply(); } });
  q.addEventListener("input", apply); sort.addEventListener("change", apply);
  addEventListener("popstate", () => { const v = new URLSearchParams(location.search).get("sort"); sort.value = SORTS.includes(v) ? v : "name"; apply(); });
  apply();
})();
