/* Runs before the first paint (a classic script in <head>), so a saved "light"/"dark" choice never flashes the other
   theme. Same rules as src/lib/theme.ts; an external file because the Content-Security-Policy forbids inline scripts. */
(function () {
  try {
    var choice = localStorage.getItem("waqti-theme");
    var dark = !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
    var shown = choice === "light" || choice === "dark" ? choice : dark ? "dark" : "light";
    if (choice === "light" || choice === "dark") document.documentElement.setAttribute("data-theme", choice);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", shown === "dark" ? "#0b1520" : "#f2f7fb");
  } catch (e) {
    /* storage blocked: the page follows the phone's setting */
  }
})();
