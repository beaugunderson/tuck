// Regenerate the social preview from the local site (no production CSP overrides).
// playwright-cli -s=tuck-site run-code --filename=Tests/site-social.js
async (page) => {
  if (!page.url().startsWith('http://127.0.0.1:8126/')) {
    throw new Error('Open http://127.0.0.1:8126/ before generating the social card.');
  }
  await page.reload();
  await page.setViewportSize({width: 1200, height: 630});
  await page.addStyleTag({content: `
    .header { padding: 24px 0 12px; }
    .header nav, .details, .install, .credits, .demo figcaption { display: none; }
    .hero { padding: 18px 0 24px; }
    .hero h1 { font-size: 76px; }
    .desktop { height: 180px; }
  `});
  await page.locator('.demo-toggle').click();
  await page.evaluate(() => document.activeElement.blur());
  await page.screenshot({path: 'site/social.png', animations: 'disabled'});
  await page.reload();
}
