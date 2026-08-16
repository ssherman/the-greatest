import { test, expect } from "@playwright/test";

test.describe("Admin — billing", () => {
  const sidebar = (page: import("@playwright/test").Page) => page.getByTestId("admin-sidebar");

  test("the Billing section links to all four screens", async ({ page }) => {
    await page.goto("/admin/memberships");

    await sidebar(page).getByRole("link", { name: "Donations", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/donations/);
    await expect(page.getByRole("heading", { name: "Donations", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Stripe Events", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/stripe_events/);
    await expect(page.getByRole("heading", { name: "Stripe Events", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Billing Plans", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/billing_plans/);
    await expect(page.getByRole("heading", { name: "Billing Plans", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Memberships", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/memberships/);
    await expect(page.getByRole("heading", { name: "Memberships", level: 1 })).toBeVisible();
  });

  test("the membership filters round-trip through the URL", async ({ page }) => {
    await page.goto("/admin/memberships");

    await page.getByLabel("Search memberships").fill("cus_");
    await page.getByRole("button", { name: "Filter" }).click();

    await expect(page).toHaveURL(/q=cus_/);
    // The page must render whether or not the dev database has a match --
    // an empty result is a legitimate outcome, not a failure.
    await expect(page.getByRole("heading", { name: "Memberships", level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Clear" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships$/);
  });

  test("the comp form is reachable and cancels back to the list", async ({ page }) => {
    await page.goto("/admin/memberships");

    await page.getByRole("link", { name: "Comp a membership" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships\/new/);
    await expect(page.getByLabel("User id")).toBeVisible();

    await page.getByRole("link", { name: "Cancel" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships$/);
  });

  test("the Stripe event status filter round-trips", async ({ page }) => {
    await page.goto("/admin/stripe_events");

    await page.getByRole("combobox").selectOption("failed");
    await page.getByRole("button", { name: "Filter" }).click();

    await expect(page).toHaveURL(/status=failed/);
    await expect(page.getByRole("heading", { name: "Stripe Events", level: 1 })).toBeVisible();
  });
});
