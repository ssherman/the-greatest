import { test, expect, type Page } from "@playwright/test";

// E2E runs against the development database, and two real jobs derive
// behaviour from what's in the ranking_configurations table:
//
//   - CreateNextYearConfiguration picks its target year as max(year) + 1 for
//     the domain, so a leftover year configuration shifts the year every
//     future "Create Next Year's Configuration" click proposes for real.
//   - dynamic_lists:regenerate iterates every configuration with a non-nil
//     year and expects a populated cutoff; a leftover with a nil cutoff
//     makes the Sidekiq job raise.
//
// So every configuration this spec creates -- including the second one
// "Create Next Year's Configuration" creates as a side effect -- is deleted
// in afterEach, whether the test passed or failed. Years 2031-2033 sit above
// any real data so a rerun can't collide with the real 2023-2025 configs.
test.describe("Books admin — dynamic year lists", () => {
  let configIdsToDelete: number[];

  test.beforeEach(({ page }) => {
    configIdsToDelete = [];
    page.on("dialog", (dialog) => dialog.accept());
  });

  test.afterEach(async ({ page }) => {
    for (const id of configIdsToDelete) {
      await page.goto(`/admin/ranking_configurations/${id}`);
      await page.getByRole("button", { name: "Delete" }).click();
      await expect(page).toHaveURL(/\/admin\/ranking_configurations$/);
    }
  });

  async function createConfiguration(page: Page, name: string, year?: string) {
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    if (year) {
      await page.locator('input[name="ranking_configuration[year]"]').fill(year);
    }
    await page.getByRole("button", { name: "Create Configuration" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const id = Number(new URL(page.url()).pathname.split("/").pop());
    configIdsToDelete.push(id);
  }

  // Locates the id of a configuration by its exact name, via the index
  // search -- used to find the second configuration that "Create Next
  // Year's Configuration" creates as a side effect, so it can be queued
  // for deletion too.
  async function findConfigurationId(page: Page, name: string): Promise<number> {
    await page.goto(`/admin/ranking_configurations?q=${encodeURIComponent(name)}`);
    const link = page.getByRole("link", { name, exact: true });
    await expect(link).toBeVisible();
    const href = await link.getAttribute("href");
    return Number(href?.split("/").pop());
  }

  test("the form offers year and both cutoff fields", async ({ page }) => {
    await page.goto("/admin/ranking_configurations/new");

    await expect(page.locator('input[name="ranking_configuration[year]"]')).toBeVisible();
    await expect(
      page.locator('input[name="ranking_configuration[primary_mapped_list_cutoff_limit]"]')
    ).toBeVisible();
    await expect(
      page.locator('input[name="ranking_configuration[secondary_mapped_list_cutoff_limit]"]')
    ).toBeVisible();
  });

  test("a year configuration shows its dynamic lists card", async ({ page }) => {
    await createConfiguration(page, `E2E Year RC ${Date.now()}`, "2031");

    await expect(page.getByText("Dynamic Lists for 2031")).toBeVisible();
    await expect(page.getByText("Not generated yet.").first()).toBeVisible();
  });

  test("Generate Dynamic Lists appears only on a year configuration", async ({ page }) => {
    await createConfiguration(page, `E2E No Year RC ${Date.now()}`);
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await expect(page.getByRole("button", { name: /Create Next Year/ })).toBeVisible();
    await expect(page.getByRole("button", { name: /Generate Dynamic Lists/ })).toHaveCount(0);

    await createConfiguration(page, `E2E Year Action RC ${Date.now()}`, "2032");
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await expect(page.getByRole("button", { name: /Generate Dynamic Lists/ })).toBeVisible();
    // Do NOT click it -- it queues a real regeneration job against the
    // development database (623 lists, author rankings, a search reindex).
    // Task 10 exercises generation deliberately, with a DB snapshot first.
  });

  test("creating next year's configuration reports what it copied", async ({ page }) => {
    await createConfiguration(page, `E2E Source RC ${Date.now()}`, "2033");
    await page.locator(".dropdown").getByText("Actions", { exact: true }).click();
    await page.getByRole("button", { name: /Create Next Year/ }).click();

    const flash = page
      .locator('[role="alert"] span')
      .filter({ hasText: "penalties copied forward" });
    await expect(flash).toBeVisible();

    const flashText = await flash.textContent();
    const match = flashText?.match(/Created (.+?): \d/);
    expect(match).not.toBeNull();

    // Queue the configuration this action created (a second, real row) for
    // deletion alongside the source configuration created above.
    configIdsToDelete.push(await findConfigurationId(page, match![1]));
  });
});
