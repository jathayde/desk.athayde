const { test, expect } = require("@playwright/test");

const scenario = (page, name, then = "/") => page.goto(`/playwright/scenarios/${name}?then=${encodeURIComponent(then)}`);

test("healthy: no banner, distance to stop is the loudest number, cash and review rows, no horizontal scroll", async ({ page }) => {
  await scenario(page, "healthy");
  await expect(page.locator(".banner")).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true);
  await expect(page.getByText("$10,240.00")).toBeVisible();
  await expect(page.getByText("1.1% to stop")).toBeVisible();
  await expect(page.getByText("$2,110.00 / $980.00")).toBeVisible();
  await expect(page.getByText("Proposals")).toBeVisible();
});

test("expiring: banner links to re-auth", async ({ page }) => {
  await scenario(page, "expiring");
  await expect(page.locator(".banner.expiring")).toContainText("Token expires");
  await expect(page.locator(".banner.expiring a", { hasText: "Re-authenticate now" })).toHaveAttribute("href", "/schwab/authorize");
});

test("expired: sync paused, every number stale, re-auth is the call to action", async ({ page }) => {
  await scenario(page, "expired");
  await expect(page.locator(".banner.expired")).toContainText("Token expired");
  await expect(page.locator(".banner.expired")).toContainText("Sync paused since");
  await expect(page.locator(".as-of.stale").first()).toBeVisible();
  await expect(page.getByRole("link", { name: "Re-authenticate with Schwab" })).toBeVisible();
});

test("halted: names who, when, and why, and keeps the rest visible", async ({ page }) => {
  await scenario(page, "halted");
  await expect(page.locator(".banner.halted")).toContainText("Halted");
  await expect(page.locator(".banner.halted")).toContainText("daily loss limit, by hand");
  await expect(page.getByText("$10,240.00")).toBeVisible();
});

test("not connected: the connect call to action", async ({ page }) => {
  await scenario(page, "not_connected");
  await expect(page.getByRole("link", { name: "Connect Schwab" })).toHaveAttribute("href", "/schwab/authorize");
});

test("needs setup: points at the system page", async ({ page }) => {
  await scenario(page, "needs_setup");
  await expect(page.getByText("Set up the trading account")).toBeVisible();
});

test("unprotected position reads as no stop and is excluded from open risk", async ({ page }) => {
  await scenario(page, "unprotected");
  await expect(page.locator(".pos.at-risk")).toContainText("no stop");
  await expect(page.getByText("excludes 1 no stop")).toBeVisible();
});

test("a failed sync with a usable token is a status line, not a banner", async ({ page }) => {
  await scenario(page, "sync_failed");
  await expect(page.locator(".banner")).toHaveCount(0);
  await expect(page.locator(".status-line")).toContainText("orders sync failed");
});
