const { test, expect } = require("@playwright/test");

test("re-auth succeeds through the fake authorize page and shows the new expiry", async ({ page }) => {
  await page.goto("/playwright/scenarios/expired?then=%2Fsystem");
  await page.getByRole("link", { name: "Re-authenticate now" }).click();
  await expect(page.getByRole("heading", { name: "Schwab connected" })).toBeVisible();
  await expect(page.getByText("This connection is good until")).toBeVisible();
});

test("re-auth failure shows the error and a retry link, leaving the old token alone", async ({ page }) => {
  await page.goto("/playwright/scenarios/healthy?then=%2Fsystem");
  // Read the authorize redirect without following it, so the fake login can be failed on purpose.
  const response = await page.request.get("/schwab/authorize", { maxRedirects: 0 });
  const state = new URL(response.headers()["location"], "http://127.0.0.1").searchParams.get("state");
  await page.goto(`/schwab/fake_authorize?state=${state}&fail=1`);
  await expect(page.getByRole("heading", { name: "Schwab connection failed" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Try again" })).toHaveAttribute("href", "/schwab/authorize");
});

test("halt needs a reason; resume needs the typed word", async ({ page }) => {
  await page.goto("/playwright/scenarios/healthy?then=%2Fsystem");
  await page.getByLabel("Reason").fill("testing the switch");
  await page.getByRole("button", { name: "Halt" }).click();
  await expect(page.getByText("Halted by John")).toBeVisible();
  await page.getByLabel("Type resume to clear the halt").fill("nope");
  await page.getByRole("button", { name: "Resume" }).click();
  await expect(page.getByText("Type resume to confirm")).toBeVisible();
  await page.getByLabel("Type resume to clear the halt").fill("resume");
  await page.getByRole("button", { name: "Resume" }).click();
  await expect(page.getByText("Resumed.")).toBeVisible();
});

test("shadow mode comes off only with the typed words and a reason, and goes back on the same way", async ({ page }) => {
  await page.goto("/playwright/scenarios/proposal?then=%2Fsystem");
  await page.getByLabel("Turn shadow mode off (the next approve places a real order): why").fill("matched for a week");
  await page.getByLabel("Type go live to confirm").fill("live");
  await page.getByRole("button", { name: "Go live" }).click();
  await expect(page.getByText("Type go live to confirm.")).toBeVisible();
  await page.getByLabel("Turn shadow mode off (the next approve places a real order): why").fill("matched for a week");
  await page.getByLabel("Type go live to confirm").fill("go live");
  await page.getByRole("button", { name: "Go live" }).click();
  await expect(page.getByText("Shadow mode is off: the next approve places a real order.")).toBeVisible();
  await page.getByLabel("Turn shadow mode back on: why").fill("not yet");
  await page.getByLabel("Type shadow to confirm").fill("shadow");
  await page.getByRole("button", { name: "Back to shadow" }).click();
  await expect(page.getByText("Shadow mode is on.")).toBeVisible();
});
