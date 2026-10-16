const { test, expect } = require("@playwright/test");

test("a drift proposal shows its drift, is approved in shadow, and the dashboard reads the row", async ({ page }) => {
  await page.goto("/playwright/scenarios/rebalance?then=%2Fproposals");
  await page.getByRole("link", { name: /SELL 11 XYZ/ }).click();
  await expect(page.getByText("Rebalance · allocation")).toBeVisible();
  await expect(page.getByText(/20\.7% of equity against a 15\.0% target/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "Stop collar" })).toHaveCount(0);
  const boxes = page.getByRole("checkbox", { name: /^I acknowledge/ });
  for (const box of await boxes.all()) await box.check();
  await page.getByLabel("Type approve to confirm").fill("approve");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByText("Shadow approval: place this order at Schwab by hand.")).toBeVisible();
  await page.goto("/");
  await expect(page.getByText(/sell 11 sh · \$583\.68 proposed/)).toBeVisible();
});

test("a human proposal already waiting makes the check step aside, and the screens say so", async ({ page }) => {
  await page.goto("/playwright/scenarios/rebalance_skipped?then=%2Fallocation");
  await expect(page.getByText(/a proposal on it is already waiting/)).toBeVisible();
  await page.goto("/proposals");
  await expect(page.getByRole("link", { name: /SELL 5 XYZ/ })).toBeVisible();
  await expect(page.getByRole("link", { name: /SELL 11 XYZ/ })).toHaveCount(0);
});
