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

const logoMenu = document.querySelector(".brand-menu");
const logoToggle = logoMenu.querySelector("summary");

// Native <details> handles click, tap, and keyboard even without JavaScript.
// Mouse hover is an extra way to find it, not the only way to use it.
logoMenu.addEventListener("pointerenter", (event) => {
  if (event.pointerType === "mouse") logoMenu.open = true;
});
logoMenu.addEventListener("pointerleave", () => {
  if (!logoMenu.contains(document.activeElement)) logoMenu.open = false;
});
logoMenu.addEventListener("focusout", (event) => {
  if (!logoMenu.contains(event.relatedTarget)) logoMenu.open = false;
});
document.addEventListener("pointerdown", (event) => {
  if (!logoMenu.contains(event.target)) logoMenu.open = false;
});

toggle.addEventListener("click", () => setTray(tray.hidden));
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  if (logoMenu.open) {
    logoMenu.open = false;
    logoToggle.focus();
  } else if (!tray.hidden) {
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
    status.textContent = "Copied.";
  } catch {
    // Leave a useful selection if clipboard permission is denied.
    const range = document.createRange();
    range.selectNodeContents(command);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = "Press ⌘C (or Ctrl+C) to copy.";
  }
});
