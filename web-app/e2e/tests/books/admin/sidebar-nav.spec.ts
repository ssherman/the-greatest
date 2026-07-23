import { test, expect } from "@playwright/test";

test.describe("Books admin — sidebar navigation", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/admin");
  });

  const sidebar = (page: import("@playwright/test").Page) => page.getByTestId("admin-sidebar");

  test("Books link navigates to the books index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Books", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/books/);
    await expect(page.getByRole("heading", { name: "Books", exact: true, level: 1 })).toBeVisible();
  });

  test("Authors link navigates to the authors index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Authors", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/authors/);
    await expect(page.getByRole("heading", { name: "Authors", level: 1 })).toBeVisible();
  });

  test("Series link navigates to the series index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Series", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/series/);
    await expect(page.getByRole("heading", { name: "Series", level: 1 })).toBeVisible();
  });

  test("Categories link navigates to the categories index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Categories", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/categories/);
    await expect(page.getByRole("heading", { name: "Categories", level: 1 })).toBeVisible();
  });

  test("Lists link navigates to the lists index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Lists", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/lists/);
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("Rankings link navigates to the ranking-configurations index", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Rankings", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/ranking_configurations/);
    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  });

  test("Penalties link navigates to the global penalties page", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Penalties" }).click();
    await expect(page).toHaveURL(/\/admin\/penalties/);
  });

  test("Users link navigates to the global users page", async ({ page }) => {
    await sidebar(page).getByRole("link", { name: "Users" }).click();
    await expect(page).toHaveURL(/\/admin\/users/);
  });
});
