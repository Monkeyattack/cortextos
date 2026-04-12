---
name: playwright
description: Use when testing web pages, checking deployments, taking screenshots, verifying UI, scraping page content, or any task needing a real browser. Triggers on "test the page", "check the site", "screenshot", "verify deployment", "does the page load", "check mobile", "scrape", "browser test", "playwright".
---

# Playwright Browser Testing Skill

## Overview

Run browser-based tests, screenshots, and page checks using Playwright on this VPS. Chromium is pre-installed. Works for any web project — not tied to a specific repo.

## Prerequisites (Already Installed)

- **Playwright:** v1.58.2 via npx
- **Chromium headless:** `~/.cache/ms-playwright/chromium_headless_shell-1208/`
- **@playwright/test:** installed in `/home/claude-dev/repos/orbfutures/node_modules/`

If a project doesn't have `@playwright/test` locally:
```bash
npm install --save-dev @playwright/test
```

## Quick Commands

### Take a Screenshot
```bash
npx playwright screenshot --browser chromium "https://example.com" screenshot.png
```

### Check if a Page Loads (Quick Health Check)
```bash
npx playwright screenshot --browser chromium --viewport-size="1280,720" "https://dashboard.profithits.app" /tmp/check.png && echo "OK" || echo "FAIL"
```

### Mobile Screenshot (iPhone viewport)
```bash
npx playwright screenshot --browser chromium --viewport-size="375,812" "https://dashboard.profithits.app" /tmp/mobile.png
```

### Run a Test File
```bash
npx playwright test path/to/test.spec.js --reporter=list
```

### Run All Tests in a Project
```bash
npx playwright test --reporter=list
```

## Writing Tests

### Test File Template
Create `tests/mytest.spec.js`:
```javascript
const { test, expect } = require('@playwright/test');
const BASE = process.env.TEST_URL || 'http://127.0.0.1:PORT';

test('page loads', async ({ page }) => {
  await page.goto(BASE);
  await expect(page).toHaveTitle(/Expected Title/);
});

test('element is visible', async ({ page }) => {
  await page.goto(`${BASE}/path`);
  await expect(page.getByText('Some Text')).toBeVisible();
});

test('API returns data', async ({ request }) => {
  const resp = await request.get(`${BASE}/api/endpoint`);
  expect(resp.ok()).toBeTruthy();
  const json = await resp.json();
  expect(json.status).toBe('ok');
});

test('mobile responsive', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 812 });
  await page.goto(BASE);
  // Check mobile-specific elements
  await expect(page.locator('#mobile-menu-button')).toBeVisible();
});
```

### Config File Template
Create `playwright.config.js` in project root:
```javascript
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 30000,
  retries: 1,
  use: {
    baseURL: process.env.TEST_URL || 'http://127.0.0.1:PORT',
    screenshot: 'only-on-failure',
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1280, height: 720 } } },
    { name: 'mobile', use: { viewport: { width: 375, height: 812 } } },
  ],
  reporter: [['list'], ['html', { open: 'never' }]],
});
```

## Common Test Patterns

### Check Multiple Pages Load
```javascript
const pages = ['/', '/about', '/api/health'];
for (const path of pages) {
  test(`${path} returns 200`, async ({ request }) => {
    const resp = await request.get(`${BASE}${path}`);
    expect(resp.ok()).toBeTruthy();
  });
}
```

### Form Submission
```javascript
test('login works', async ({ page }) => {
  await page.goto(`${BASE}/login`);
  await page.fill('input[name="email"]', 'test@example.com');
  await page.fill('input[name="password"]', 'password');
  await page.click('button[type="submit"]');
  await expect(page).toHaveURL(/dashboard/);
});
```

### Wait for Dynamic Content
```javascript
test('data loads via HTMX/AJAX', async ({ page }) => {
  await page.goto(BASE);
  // Wait for element that loads dynamically
  await page.waitForSelector('.data-loaded', { timeout: 10000 });
  await expect(page.locator('.data-loaded')).toBeVisible();
});
```

### Screenshot Comparison
```javascript
test('visual regression', async ({ page }) => {
  await page.goto(BASE);
  await expect(page).toHaveScreenshot('homepage.png', { maxDiffPixels: 100 });
});
```

### Check Responsive Breakpoints
```javascript
const viewports = [
  { name: 'mobile', width: 375, height: 812 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'desktop', width: 1280, height: 720 },
];

for (const vp of viewports) {
  test(`renders on ${vp.name}`, async ({ page }) => {
    await page.setViewportSize({ width: vp.width, height: vp.height });
    await page.goto(BASE);
    await expect(page.locator('main')).toBeVisible();
    await page.screenshot({ path: `/tmp/${vp.name}.png` });
  });
}
```

## Locator Best Practices

Use specific locators to avoid strict mode violations:
```javascript
// BAD: matches multiple elements
page.locator('text=Submit')

// GOOD: scope to a specific area
page.getByRole('main').getByText('Submit')
page.locator('form button[type="submit"]')
page.getByRole('button', { name: 'Submit' })
page.getByText('Submit').first()
page.locator('#specific-id')
```

## Debugging

### View failure screenshots
```bash
ls test-results/*/test-failed-*.png
```

### View trace (interactive)
```bash
npx playwright show-trace test-results/*/trace.zip
```

### Run with headed browser (requires X11/display)
```bash
npx playwright test --headed
```

### Run single test
```bash
npx playwright test -g "test name pattern"
```

## Testing Against Different Targets

```bash
# Local dev server
TEST_URL=http://127.0.0.1:3000 npx playwright test

# Staging
TEST_URL=https://staging.example.com npx playwright test

# Production
TEST_URL=https://example.com npx playwright test
```

## Existing Test Suites on This VPS

| Project | Test File | URL | Command |
|---------|-----------|-----|---------|
| MOV Dashboard | `orbfutures/tests/dashboard.spec.js` | `http://127.0.0.1:8101` | `cd ~/repos/orbfutures && npx playwright test` |

## Notes

- Always test against `http://127.0.0.1:PORT` from the VPS (avoids Cloudflare/SSL overhead)
- Use `--project=desktop` or `--project=mobile` to run only one viewport
- Tests run headless by default — no display needed
- Screenshots saved to `test-results/` on failure
- Keep tests fast: use `request` for API checks, `page` only when you need a real browser
