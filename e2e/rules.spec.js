import { test, expect } from "@playwright/test";

test("a rule is previewed over the waiting proposal, then saved as a new version", async ({ page }) => {
  await page.goto("/playwright/scenarios/proposal?then=%2Frisk_rules");
  const cap = page.locator("section.rule", { hasText: "Notional cap" });
  await cap.getByLabel("Per order").fill("1000");
  await cap.getByRole("button", { name: "Preview effect" }).click();
  await expect(page.getByRole("heading", { name: "Preview: Notional cap v2" })).toBeVisible();
  await expect(page.getByText("pass → blocks")).toBeVisible();
  await page.getByRole("link", { name: "Back to rules" }).click();
  // Turbo shows the cached rules page first; typing into that snapshot is lost when the fresh render lands.
  await expect(page.getByRole("heading", { name: "Rules", exact: true })).toBeVisible();
  await expect(page.locator("html")).not.toHaveAttribute("data-turbo-preview");
  await cap.getByLabel("Per order").fill("1000");
  await cap.getByLabel("Why").fill("smaller account");
  await cap.getByRole("button", { name: "Save as v2" }).click();
  await expect(page.getByText("Notional cap is now version 2.")).toBeVisible();
  await expect(page.locator("section.rule", { hasText: "Notional cap" })).toContainText("v2 · smaller account");
});
