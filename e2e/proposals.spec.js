const { test, expect } = require("@playwright/test");

async function acknowledgeAll(page) {
  const boxes = page.getByRole("checkbox", { name: /^I acknowledge/ });
  await expect(boxes.first()).toBeVisible();
  for (const box of await boxes.all()) await box.check();
}

test("a warning must be acknowledged before the approve goes through", async ({ page }) => {
  await page.goto("/playwright/scenarios/proposal_warn?then=%2Fproposals");
  await page.getByRole("link", { name: /BUY \d+ XYZ/ }).click();
  await expect(page.getByLabel(/I acknowledge wash sale/)).toBeVisible();
  await page.getByLabel(/I acknowledge max sector exposure/).check();
  await page.getByLabel(/I acknowledge earnings blackout/).check();
  await page.getByLabel("Type approve to confirm").fill("approve");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByText("acknowledge wash sale first")).toBeVisible();
  await expect(page.getByText("Approved in shadow mode")).toHaveCount(0);
});

test("a hard fail is rejected by rules with nothing to approve", async ({ page }) => {
  await page.goto("/playwright/scenarios/proposal_blocked?then=%2Fproposals");
  await expect(page.getByText("Nothing waiting on you.")).toBeVisible();
  await page.getByRole("link", { name: /BUY \d+ XYZ/ }).click();
  await expect(page.getByRole("heading", { name: /rejected by rules/ })).toBeVisible();
  await expect(page.getByText("Notional cap")).toBeVisible();
  await expect(page.getByRole("button", { name: "Approve" })).toHaveCount(0);
});

test("a stop outside the collar needs a reason, then approves in shadow", async ({ page }) => {
  await page.goto("/playwright/scenarios/proposal_override?then=%2Fproposals");
  await page.getByRole("link", { name: /BUY \d+ XYZ/ }).click();
  await acknowledgeAll(page);
  await page.getByLabel("Type approve to confirm").fill("approve");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByText("an override reason is required")).toBeVisible();
  await acknowledgeAll(page);
  await page.getByLabel("The stop is outside the collar. Why?").fill("wide stop on purpose, half size");
  await page.getByLabel("Type approve to confirm").fill("approve");
  await page.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByText("Approved in shadow mode")).toBeVisible();
  await expect(page.getByText("Override: wide stop on purpose, half size")).toBeVisible();
});

test("a submission unknown is the dashboard banner and the proposal's warning", async ({ page }) => {
  await page.goto("/playwright/scenarios/submission_unknown?then=%2F");
  await expect(page.locator(".banner")).toContainText("Submission unknown");
  await page.locator(".banner").getByRole("link", { name: "XYZ" }).click();
  await expect(page.getByText("check Schwab before doing anything else")).toBeVisible();
});

test("a rule halt refuses entries on the dashboard and the form while an exit still previews", async ({ page }) => {
  await page.goto("/playwright/scenarios/rule_halted?then=%2F");
  await expect(page.locator(".status-line")).toContainText("Entries halted by daily loss halt: down 3.2% today; exits stay available");
  await page.goto("/proposals/new?kind=exit&symbol=XYZ&limit_price=53");
  await expect(page.getByRole("heading", { name: /Preview: SELL 40 XYZ/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Propose", exact: true })).toBeVisible();
  await page.goto("/proposals/new?kind=entry&symbol=XYZ&limit_price=50&stop_price=47");
  await expect(page.getByRole("heading", { name: /Preview: BUY \d+ XYZ/ })).toBeVisible();
  await expect(page.getByRole("button", { name: "Propose anyway (it will be rejected by rules)" })).toBeVisible();
});
