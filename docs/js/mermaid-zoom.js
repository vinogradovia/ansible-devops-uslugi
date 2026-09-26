/* Автоматически оборачивает все mermaid-диаграммы в zoom-контейнеры и вешает обработчики.
   Использует MutationObserver на .mermaid элемент — mermaid рендерит SVG асинхронно,
   вставляя <svg> внутрь .mermaid div. DOMContentLoaded срабатывает раньше рендеринга,
   поэтому нужно ждать появления дочерних узлов. */
document.addEventListener("DOMContentLoaded", () => {
  const processed = new WeakSet();

  function wrapMermaid(el) {
    if (processed.has(el)) return;
    processed.add(el);

    const svg = el.querySelector("svg");
    if (!svg) return;

    const wrapper = document.createElement("div");
    wrapper.className = "mermaid-zoom-wrapper";

    const btn = document.createElement("button");
    btn.className = "mermaid-zoom-btn";
    btn.textContent = "Zoom";
    btn.setAttribute("title", "Открыть диаграмму на весь экран");

    wrapper.appendChild(btn);
    wrapper.appendChild(el);
    el.parentElement.replaceChild(wrapper, el);

    btn.addEventListener("click", () => {
      const overlay = document.createElement("div");
      overlay.className = "mermaid-zoom-overlay";

      const closeBtn = document.createElement("button");
      closeBtn.className = "mermaid-zoom-close";
      closeBtn.textContent = "✕";
      closeBtn.setAttribute("aria-label", "Закрыть");

      const container = document.createElement("div");
      container.className = "mermaid-zoom-container";
      container.appendChild(svg.cloneNode(true));

      overlay.appendChild(closeBtn);
      overlay.appendChild(container);
      document.body.appendChild(overlay);

      const remove = () => {
        if (document.body.contains(overlay)) {
          document.body.removeChild(overlay);
        }
      };

      closeBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        remove();
      });

      overlay.addEventListener("click", (e) => {
        if (e.target === overlay) remove();
      });

      document.addEventListener("keydown", function escHandler(e) {
        if (e.key === "Escape") {
          remove();
          document.removeEventListener("keydown", escHandler);
        }
      });
    });
  }

  // Уже отрендеренные
  document.querySelectorAll(".mermaid").forEach(wrapMermaid);

  // Ловим появление SVG внутри .mermaid — mermaid вставляет <svg> как child
  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      const mermaidEl = mutation.target;
      if (!mermaidEl.classList?.contains("mermaid")) continue;
      wrapMermaid(mermaidEl);
    }
  });

  document.querySelectorAll(".mermaid").forEach(el => {
    observer.observe(el, { childList: true, subtree: true });
  });
});
