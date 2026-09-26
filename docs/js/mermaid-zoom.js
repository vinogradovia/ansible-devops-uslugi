/* Автоматически оборачивает все mermaid-диаграммы в zoom-контейнеры.
   Material theme рендерит mermaid из <pre class="mermaid"><code> в SVG через
   mermaid.js (CDN). SVG появляется после DOMContentLoaded + выполнения mermaid. */
(function() {
  var processed = new Set();

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
      closeBtn.textContent = "\u2715";
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

  function tryWrapAll() {
    document.querySelectorAll("pre.mermaid, div.mermaid").forEach(function(el) {
      if (el.querySelector("svg")) {
        wrap(el);
      }
    });
  }

  // Initial pass
  tryWrapAll();

  // Wait for mermaid.js to finish rendering
  // Material theme loads mermaid from CDN — it may render after load
  window.addEventListener("load", function() {
    setTimeout(tryWrapAll, 100);
    setTimeout(tryWrapAll, 500);
    setTimeout(tryWrapAll, 1000);
  });

  // MutationObserver — catch any mermaid elements added dynamically
  var observer = new MutationObserver(function(mutations) {
    tryWrapAll();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  // Build version: загружаем build-info.json и вставляем в footer
  fetch("/build-info.json")
    .then(function(r) { return r.text(); })
    .then(function(text) {
      var match = text.match(/commit:\s*(\S+)/);
      if (!match) return;
      var hash = match[1];
      var shortHash = hash.slice(0, 7);
      var versionEl = document.createElement("div");
      versionEl.className = "build-version";
      versionEl.innerHTML = 'Сборка: <a href="https://github.com/anomalycs/devops-uslugi/tree/' + hash + '" target="_blank" rel="noopener">' + shortHash + '</a>';
      var footer = document.querySelector("footer.md-footer");
      if (footer) {
        footer.appendChild(versionEl);
      } else {
        var mdSource = document.querySelector("a.md-source");
        if (mdSource) {
          mdSource.parentElement.insertBefore(versionEl, mdSource.nextSibling);
        }
      }
    })
    .catch(function() {
      // build-info.json нет (локальная сборка без CI) — не критично
    });
})();
