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

test("targets are added, reweighed, and retired from percents, and an instrument is classed and tagged", async ({ page }) => {
  await page.goto("/playwright/scenarios/allocation_desk?then=%2Fallocation");
  await expect(page.getByText("No targets. Nothing is measured until one exists.")).toBeVisible();
  await page.getByLabel("Symbol (or leave blank for a class)").fill("xyz");
  await page.getByLabel("Target, percent of equity").fill("15");
  await page.getByRole("button", { name: "Add target" }).click();
  await expect(page.getByText("XYZ targets 15.00%.")).toBeVisible();
  await page.getByLabel("Asset class").fill("bonds");
  await page.getByLabel("Target, percent of equity").fill("90");
  await page.getByRole("button", { name: "Add target" }).click();
  await expect(page.getByText(/105\.0%, past 100%/)).toBeVisible();
  const row = page.locator("li", { hasText: "not measured yet" });
  await row.getByLabel("Target %").fill("20");
  await row.getByRole("button", { name: "Reweigh" }).click();
  await expect(page.getByText("XYZ targets 20.00%.")).toBeVisible();
  const def = page.locator("form.classify", { hasText: "DEF" });
  await def.getByLabel("Class").fill("US equity");
  await def.getByLabel("diversifier").check();
  await def.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("DEF saved.")).toBeVisible();
  await expect(page.locator("form.classify", { hasText: "DEF" }).getByLabel("Class")).toHaveValue("us equity");
  await page.getByRole("button", { name: "Retire" }).click();
  await expect(page.getByText("XYZ no longer has a target.")).toBeVisible();
});

test("a thesis review shows the thesis and the numbers, refuses a hold without a reason, and holds with one", async ({ page }) => {
  await page.goto("/playwright/scenarios/thesis_review?then=%2Fproposals");
  await page.getByRole("link", { name: "Thesis review: TQQQ" }).click();
  await expect(page.getByText("TQQQ is tagged amplified")).toBeVisible();
  await expect(page.getByText("Levered Nasdaq into the cutting cycle.")).toBeVisible();
  await expect(page.getByText(/20\.5% against a 10\.0% target/)).toBeVisible();
  await page.getByRole("button", { name: "Hold" }).click();
  await expect(page.getByText("a hold needs a reason")).toBeVisible();
  await page.getByLabel("Hold, because").fill("riding the trend into earnings");
  await page.getByRole("button", { name: "Hold" }).click();
  await expect(page.getByText(/Holding TQQQ/)).toBeVisible();
  await expect(page.getByRole("link", { name: "Thesis review: TQQQ" })).toBeVisible(); // now under Decided
  await expect(page.getByText("Nothing waiting on you.")).toBeVisible();
});

test("a thesis review deployed opens the entry form prefilled", async ({ page }) => {
  await page.goto("/playwright/scenarios/thesis_review?then=%2Fproposals");
  await page.getByRole("link", { name: "Thesis review: TQQQ" }).click();
  await page.getByRole("button", { name: /Deploy/ }).click();
  await expect(page.getByText("Deploy TQQQ: write the entry.")).toBeVisible();
  await expect(page.getByLabel("Symbol")).toHaveValue("TQQQ");
  await expect(page.getByLabel("Thesis")).toHaveValue("Levered Nasdaq into the cutting cycle.");
});

test("a deposit under ask-each-time is staged over weeks and the dashboard says so", async ({ page }) => {
  await page.goto("/playwright/scenarios/deposit_ask?then=%2Fproposals");
  await page.getByRole("link", { name: /Thesis review: \$2,500\.00 deposited/ }).click();
  await expect(page.getByRole("button", { name: "Deploy at the next check" })).toBeVisible();
  await page.getByLabel("Stage over this many weeks").fill("3");
  await page.getByRole("button", { name: "Stage" }).click();
  await expect(page.getByText(/staged in weekly tranches/)).toBeVisible();
  await page.goto("/");
  await expect(page.getByText(/Deploying \$2,500\.00 deposited .*: 3 weekly tranches to go; drift buys wait until it is done\./)).toBeVisible();
});
