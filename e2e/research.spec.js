const { test, expect } = require("@playwright/test");

test("the operator forecasts blind to the agent, then sees both, and a resolved forecast reads as scored", async ({ page }) => {
  await page.goto("/playwright/scenarios/forecasts?then=%2Fproposals");
  await page.getByRole("link", { name: /BUY \d+ XYZ/ }).click();
  await expect(page.getByText("hidden until you add yours")).toBeVisible();
  await expect(page.getByText("62.0%")).toHaveCount(0);
  await expect(page.getByText("Hidden until you add your forecast")).toBeVisible();
  await page.getByLabel("Probability (0 to 1)").fill("0.45");
  await page.getByLabel("Horizon (sessions)").fill("8");
  await page.getByRole("button", { name: "Add my forecast" }).click();
  await expect(page.getByText("Forecast recorded.")).toBeVisible();
  await expect(page.getByText(/62\.0% within 10 sessions/)).toBeVisible();
  await expect(page.getByText(/45\.0% within 8 sessions/)).toBeVisible();
  await expect(page.getByRole("button", { name: "Add my forecast" })).toHaveCount(0);
  await page.goto("/proposals");
  await page.getByRole("link", { name: /DEF/ }).first().click();
  await expect(page.getByText(/55\.0% within 10 sessions .* hit/)).toBeVisible();
});

test("the research screen shows calibration, and a hypothesis is tested and decided on its frozen verdict", async ({ page }) => {
  await page.goto("/playwright/scenarios/research?then=%2Fresearch");
  await expect(page.getByText("not distinguishable from the baseline")).toBeVisible();
  await expect(page.getByText("2 never entered")).toBeVisible();
  const ready = page.locator("li", { hasText: "Breakouts on volume pay" });
  await expect(ready.getByText(/Verdict if decided now: .* clears the bar/)).toBeVisible();
  await ready.getByPlaceholder("why", { exact: true }).fill("it held on the holdout");
  await ready.getByRole("button", { name: "Accept" }).click();
  await expect(page.getByText(/Hypothesis #\d+ accepted\./)).toBeVisible();
  await expect(page.locator("li", { hasText: "Breakouts on volume pay" }).getByText(/^Verdict: /)).toBeVisible();
  const proposed = page.locator("li", { hasText: "Pullbacks to the 20-day hold" });
  await proposed.getByPlaceholder("why test it now").fill("a quiet tape for pullbacks");
  await proposed.getByRole("button", { name: "Start testing" }).click();
  await expect(page.getByText(/is being tested: name it on the entries/)).toBeVisible();
  await expect(page.getByText("2 hypotheses tested so far")).toBeVisible();
});
