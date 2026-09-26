/* Автоматически оборачивает все mermaid-диаграммы в zoom-контейнеры.
   Mermaid Material рендерит SVG в <body> после document.readyState='interactive',
   поэтому используем window.onload + setTimeout как fallback. */
(function() {
  var processed = new WeakSet();

  function wrap(el) {
    if (processed.has(el)) return;
    processed.add(el);

    var svg = el.querySelector("svg");
    if (!svg) return;

    var wrapper = document.createElement("div");
    wrapper.className = "mermaid-zoom-wrapper";

    var btn = document.createElement("button");
    btn.className = "mermaid-zoom-btn";
    btn.textContent = "Zoom";
    btn.setAttribute("title", "Открыть диаграмму на весь экран");

    wrapper.appendChild(btn);
    wrapper.appendChild(el);
    el.parentElement.replaceChild(wrapper, el);

    btn.addEventListener("click", function() {
      var overlay = document.createElement("div");
      overlay.className = "mermaid-zoom-overlay";

      var closeBtn = document.createElement("button");
      closeBtn.className = "mermaid-zoom-close";
      closeBtn.textContent = "✕";
      closeBtn.setAttribute("aria-label", "Закрыть");

      var container = document.createElement("div");
      container.className = "mermaid-zoom-container";
      container.appendChild(svg.cloneNode(true));

      overlay.appendChild(closeBtn);
      overlay.appendChild(container);
      document.body.appendChild(overlay);

      function remove() {
        if (document.body.contains(overlay)) {
          document.body.removeChild(overlay);
        }
      }

      closeBtn.addEventListener("click", function(e) {
        e.stopPropagation();
        remove();
      });

      overlay.addEventListener("click", function(e) {
        if (e.target === overlay) remove();
      });

      document.addEventListener("keydown", function esc(e) {
        if (e.key === "Escape") {
          remove();
          document.removeEventListener("keydown", esc);
        }
      });
    });
  }

  function tryWrap() {
    var found = false;
    document.querySelectorAll(".mermaid").forEach(function(el) {
      if (el.querySelector("svg")) {
        wrap(el);
        found = true;
      }
    });
    return found;
  }

  // Пробуем сразу
  tryWrap();

  // retry — mermaid рендерит синхронно при document.readyState='interactive'
  // в Material theme SVG появляется до load, но после DOMContentLoaded
  var attempts = 0;
  var maxAttempts = 20;
  var interval = setInterval(function() {
    attempts++;
    if (tryWrap() || attempts >= maxAttempts) {
      clearInterval(interval);
    }
  }, 50);

  // final fallback на load
  window.addEventListener("load", function() {
    setTimeout(tryWrap, 0);
  });
})();
