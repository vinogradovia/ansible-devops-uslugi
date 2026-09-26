/* Автоматически оборачивает все mermaid-диаграммы в zoom-контейнеры и вешает обработчики. */
document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".mermaid").forEach(mermaidEl => {
    const svg = mermaidEl.querySelector("svg");
    if (!svg) return;

    const wrapper = document.createElement("div");
    wrapper.className = "mermaid-zoom-wrapper";

    const btn = document.createElement("button");
    btn.className = "mermaid-zoom-btn";
    btn.textContent = "Zoom";
    btn.setAttribute("title", "Открыть диаграмму на весь экран");

    wrapper.appendChild(btn);
    wrapper.appendChild(mermaidEl);

    mermaidEl.parentElement.replaceChild(wrapper, mermaidEl);

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
  });
});
