import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Books list wizard spec §10: the whole flow on a three-row list, with the
// real parser and finder (a few cents of AI per run). Needs Sidekiq running
// against THIS checkout and the Open Library service reachable. A row whose
// match had a failed source is retried (up to 3 attempts) before it is
// flagged, so the Match wait below allows for the retries.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const cleanup = () => execSync("bin/rails e2e:list_wizard_cleanup", { cwd: WEB_APP, encoding: "utf8" });

test.describe("Books admin — list wizard", () => {
  test.setTimeout(480_000);

  // Sweep orphans from earlier failed runs, and guarantee removal after this one.
  test.beforeAll(() => {
    cleanup();
  });
  test.afterEach(() => {
    cleanup();
  });

  test("parses, matches, reviews, imports and finishes a three-row list", async ({ page }) => {
    const name = `E2E Wizard List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    const listUrl = page.url();

    await page.getByRole("link", { name: /Launch Wizard/ }).click();
    await page.getByLabel("List content").fill(
      [
        "1. Pride and Prejudice by Jane Austen",
        "2. Moby-Dick by Herman Melville",
        "3. The Glass Orchard of Vellmoor by Tamsin Okonkwo-Reyes",
      ].join("\n"),
    );
    await page.getByRole("button", { name: "Save and parse" }).click();

    await expect(page.getByTestId("parsed-rows")).toContainText("Pride and Prejudice", { timeout: 120_000 });
    await expect(page.getByTestId("parsed-rows").locator("tbody tr")).toHaveCount(3);
    await page.getByRole("button", { name: "Match →" }).click();

    await expect(page.getByTestId("match-counts")).toBeVisible({ timeout: 300_000 });
    await page.getByRole("button", { name: "Review →" }).click();

    // The default view is flagged rows only: the two famous books matched.
    // A failure on this count usually means Open Library data or availability
    // (the home-server service must be reachable), not app code.
    const rows = page.getByTestId("review-row");
    await expect(rows).toHaveCount(1);
    const madeUp = rows.filter({ hasText: "Glass Orchard" });
    await expect(madeUp).toContainText("No match found");

    page.once("dialog", (dialog) => dialog.accept());
    await madeUp.getByText("More actions").click();
    await madeUp.getByRole("button", { name: "Remove" }).click();
    await expect(page.getByTestId("review-row")).toHaveCount(0);

    await page.getByRole("button", { name: "Import →" }).click();
    await expect(page.getByTestId("import-summary")).toBeVisible({ timeout: 120_000 });
    await page.getByRole("button", { name: "Done →" }).click();

    const done = page.getByTestId("done-summary");
    await expect(done.locator('[data-stat="matched"] .stat-value')).toHaveText("2");
    await expect(done.locator('[data-stat="unlinked"] .stat-value')).toHaveText("0");

    // Clean up: the list (its two rows link existing books; nothing was created).
    await page.goto(listUrl);
    page.once("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Delete", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/lists$/);
  });
});
