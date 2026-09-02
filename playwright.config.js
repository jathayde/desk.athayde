const { defineConfig } = require("@playwright/test");

// The Rails server is booted by bin/playwright in the test environment with the fake Schwab adapter.
module.exports = defineConfig({
  testDir: "./e2e",
  timeout: 30000,
  fullyParallel: false,
  workers: 1,
  use: { baseURL: process.env.BASE_URL || "http://127.0.0.1:3100", headless: true, screenshot: "only-on-failure" },
  projects: [ { name: "chromium", use: { browserName: "chromium", viewport: { width: 390, height: 844 } } } ]
});
