const { test, expect } = require("@playwright/test");

test("review queue: skip persists across reload, save moves to the next, not-a-setup-trade excludes", async ({ page }) => {
  await page.goto("/playwright/scenarios/review_queue?then=%2Ftrades");
  await page.getByRole("link", { name: /Needs review \(2\)/ }).click();
  await page.getByRole("link", { name: "LBAS" }).click();
  await expect(page.getByText("1 more to review")).toBeVisible();
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expect(page).toHaveURL(/\/trades\/\d+\/review/);
  await page.reload();
  await expect(page.getByRole("heading")).toContainText("Is this part of a setup?");
  await page.getByPlaceholder("or create a new setup by name").fill("breakout-A");
  await page.getByLabel("Planned stop").fill("18");
  await page.getByLabel("Thesis").fill("legacy holding, base breakout");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Reviewed")).toBeVisible();
  await page.getByRole("button", { name: "Not a setup trade" }).click();
  await expect(page).toHaveURL(/filter=needs_review/);
  await expect(page.getByText("Nothing waiting on you.")).toBeVisible();
});

test("post-mortem: one line and a choice, saved from the phone", async ({ page }) => {
  await page.goto("/playwright/scenarios/closed_trade?then=%2Ftrades");
  await page.getByRole("link", { name: "Closed" }).click();
  await page.getByRole("link", { name: "XYZ" }).click();
  await expect(page.getByText("+1.81R")).toBeVisible();
  await page.getByPlaceholder("What actually happened…").fill("held to target, sold into strength");
  await page.getByLabel("Followed setup").check();
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.locator(".post-mortem .thesis")).toContainText("held to target, sold into strength · followed setup");
});
