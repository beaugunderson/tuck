const toggle = document.querySelector(".demo-toggle");
const tray = document.querySelector("#demo-tray");

function setTray(open) {
  toggle.setAttribute("aria-expanded", String(open));
  toggle.setAttribute(
    "aria-label",
    `${open ? "Hide" : "Show"} hidden icons in demo`,
  );
  tray.hidden = !open;
}

toggle.addEventListener("click", () => setTray(tray.hidden));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !tray.hidden) {
    setTray(false);
    toggle.focus();
  }
});

for (const swatch of document.querySelectorAll(".theme-swatch")) {
  swatch.addEventListener("click", () => {
    document.querySelector(".desktop").dataset.theme = swatch.dataset.theme;
    for (const button of document.querySelectorAll(".theme-swatch")) {
      button.setAttribute("aria-pressed", String(button === swatch));
    }
  });
}

const copy = document.querySelector("#copy-brew");
copy.addEventListener("click", async () => {
  const command = document.querySelector("#brew-command");
  const status = document.querySelector("#copy-status");
  try {
    await navigator.clipboard.writeText(command.textContent);
    status.textContent = "Copied. Your terminal awaits.";
  } catch {
    // Leave a useful selection if clipboard permission is denied.
    const range = document.createRange();
    range.selectNodeContents(command);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = "Select the command and press ⌘C (or Ctrl+C) to copy.";
  }
});
