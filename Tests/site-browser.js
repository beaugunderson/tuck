// Run against an already-open local or deployed site:
// playwright-cli -s=tuck-site run-code --filename=Tests/site-browser.js
async (page) => {
  const checks = [];
  const check = (value, name) => {
    if (!value) throw new Error(name);
    checks.push(name);
  };
  const base = await page.evaluate(() => new URL("/", location.href).href);
  const errors = [];
  const onError = (error) => errors.push(error.message);
  page.on("pageerror", onError);
  await page.goto(base);
  check(
    (await page.title()) === "Tuck — a little less menu bar.",
    "Page title",
  );
  check((await page.locator("h1").count()) === 1, "One main heading");
  check(
    (await page.locator('a[href="/download"]').count()) === 2,
    "Both download links use the latest-release redirect",
  );
  check(
    (await page.locator(".promise").innerText()).includes(
      "Tuck will always be free",
    ),
    "Free forever promise",
  );
  check(await page.locator("#demo-tray").isHidden(), "Demo starts tucked");
  await page.getByRole("button", { name: "Show hidden icons in demo" }).click();
  check(await page.locator("#demo-tray").isVisible(), "Click reveals the tray");
  await page
    .getByRole("button", { name: "Dark menu bar", exact: true })
    .click();
  check(
    (await page.locator(".desktop").getAttribute("data-theme")) === "dark",
    "Theme control changes the menu bar",
  );
  check(
    await page.evaluate(
      () =>
        getComputedStyle(document.querySelector(".menu-bar"))
          .backgroundColor ===
        getComputedStyle(document.querySelector(".demo-tray")).backgroundColor,
    ),
    "Tray color matches menu bar",
  );
  await page.keyboard.press("Escape");
  check(await page.locator("#demo-tray").isHidden(), "Escape tucks the icons");
  check(
    await page
      .locator(".demo-toggle")
      .evaluate((el) => el === document.activeElement),
    "Escape restores focus",
  );
  await page.keyboard.press("Enter");
  check(
    await page.locator("#demo-tray").isVisible(),
    "Keyboard can reveal icons",
  );
  await page
    .getByRole("button", { name: "Blue menu bar", exact: true })
    .click();
  await page.evaluate(() =>
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async (text) => {
          window.__copiedCommand = text;
        },
      },
    }),
  );
  await page
    .getByRole("button", { name: "Copy Homebrew install command" })
    .click();
  check(
    (await page.evaluate(() => window.__copiedCommand)) ===
      "brew install --cask beaugunderson/tap/tuck",
    "Copy command is exact (clipboard stubbed)",
  );
  await page.evaluate(() =>
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        writeText: async () => {
          throw new Error("Denied");
        },
      },
    }),
  );
  await page
    .getByRole("button", { name: "Copy Homebrew install command" })
    .click();
  check(
    (await page.locator("#copy-status").innerText()).includes("⌘C"),
    "Clipboard denial offers manual copy",
  );
  check(
    (await page.evaluate(() => window.getSelection().toString())) ===
      "brew install --cask beaugunderson/tap/tuck",
    "Clipboard fallback selects the command",
  );
  await page.evaluate(() => window.getSelection().removeAllRanges());
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({ width, height: 1000 });
    check(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
      `No horizontal overflow at ${width}px`,
    );
    const tray = await page.locator("#demo-tray").boundingBox();
    check(
      tray.x >= 0 && tray.x + tray.width <= width,
      `Open tray fits at ${width}px`,
    );
  }
  await page.emulateMedia({ reducedMotion: "reduce" });
  check(
    (await page
      .locator("html")
      .evaluate((el) => getComputedStyle(el).scrollBehavior)) === "auto",
    "Reduced motion disables smooth scrolling",
  );
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => scrollTo(0, 0));
  await page.screenshot({ path: "tmp/tuck-site-mobile.png", fullPage: true });
  await page.setViewportSize({ width: 1440, height: 1100 });
  await page.screenshot({ path: "tmp/tuck-site-full.png", fullPage: true });
  const noJS = await page
    .context()
    .browser()
    .newContext({ javaScriptEnabled: false });
  const staticPage = await noJS.newPage();
  await staticPage.goto(base);
  check(
    (await staticPage.locator('a[href="/download"]').count()) === 2,
    "Download works without JavaScript",
  );
  check(
    (await staticPage.locator("#brew-command").innerText()).includes(
      "brew install",
    ),
    "Brew instructions work without JavaScript",
  );
  await noJS.close();
  check(errors.length === 0, "No browser script errors");
  page.off("pageerror", onError);
  return { passed: checks.length, checks };
}
