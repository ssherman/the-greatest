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
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
  });

  test("updates a ranking configuration", async ({ page }) => {
    const name = `E2E Edit RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page).toHaveURL(/\/edit/);
    const updated = `E2E Updated RC ${Date.now()}`;
    await page.locator('input[name="ranking_configuration[name]"]').fill(updated);
    await page.getByRole("button", { name: "Update Configuration" }).click();
    await expect(page.getByRole("heading", { name: updated, level: 1 })).toBeVisible();
  });

  test("show page displays the refresh/recalculate action buttons", async ({ page }) => {
    const name = `E2E Actions RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await expect(page.getByRole("button", { name: /Refresh Rankings/ })).toBeVisible();
  });

  test("deletes a ranking configuration", async ({ page }) => {
    const name = `E2E Delete RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/ranking_configurations$/);
  });
});
