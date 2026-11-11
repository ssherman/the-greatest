import { test, expect } from "@playwright/test";

// One serial flow: archive the primary ranking, check the admin and public
// pages, hide it, then delete it so the run leaves nothing behind.
test.describe.configure({ mode: "serial" });

test.describe("Books admin — ranking archives", () => {
  test("archives the primary ranking, shows it publicly, hides it and deletes it", async ({ page }) => {
    const name = `E2E Archive ${Date.now()}`;

    // 1. Archive the primary configuration.
    await page.goto("/admin/ranking_configurations");
    const primaryRow = page
      .locator("table tbody tr")
      .filter({ has: page.locator(".badge-primary", { hasText: "Primary" }) })
      .first();
    await primaryRow.getByRole("link").nth(1).click();
    await page.getByLabel("Archive name").fill(name);
    await page.getByRole("button", { name: "Archive now" }).click();
    await expect(page.getByText(name).first()).toBeVisible();

    // 2. It is listed in admin; read its slug from the show page.
    await page.goto("/admin/ranking_archives");
    await page.getByRole("link", { name, exact: true }).first().click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const slug = (await page.locator("dt", { hasText: "Slug" }).locator("xpath=following-sibling::dd").textContent())!.trim();
    expect(slug).toContain("e2e-archive-");
    const adminShowUrl = page.url();
    await expect(page.getByRole("link", { name: "Public page" })).toBeVisible();

    // 3. Public list and archive page.
    await page.goto("/rankings/archive");
    await expect(page.getByRole("link", { name, exact: true })).toBeVisible();
    await page.getByRole("link", { name, exact: true }).click();
    await expect(page.getByTestId("archived-ranking-notice")).toBeVisible();
    await expect(page.getByTestId("archive-no-filters")).toBeVisible();
    await expect(page.getByText("Rank #1", { exact: true }).first()).toBeVisible();
    await expect(page.getByTestId("download-csv")).toBeVisible();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", "noindex, follow");

    // 4. Page 2 starts at #101.
    await page.goto(`/rankings/archive/${slug}/page/2`);
    await expect(page.getByText("Rank #101", { exact: true }).first()).toBeVisible();

    // 5. Hide it.
    await page.goto(adminShowUrl);
    await page.getByRole("link", { name: "Edit" }).click();
    await page.locator('input[name="books_ranking_archive[hidden]"][type="checkbox"]').check();
    await page.getByRole("button", { name: "Update Archive" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "Public page" })).toHaveCount(0);
    // page.request, not goto: the page was served with a 24-hour Cache-Control.
    const hidden = await page.request.get(`/rankings/archive/${slug}`);
    expect(hidden.status()).toBe(404);

    // 6. Delete it.
    page.once("dialog", (d) => d.accept());
    await page.getByRole("button", { name: "Delete" }).click();
    await expect(page).toHaveURL(/\/admin\/ranking_archives$/);
    await expect(page.getByRole("link", { name, exact: true })).toHaveCount(0);
  });
});
