import { test, expect } from "@playwright/test";

test.describe("Books admin — ranking configurations", () => {
  test("lists ranking configurations", async ({ page }) => {
    await page.goto("/admin/ranking_configurations");
    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  });

  test("creates a ranking configuration", async ({ page }) => {
    const name = `E2E RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: /Create|Save/ }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });
});
