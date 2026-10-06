import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Approves the seeded import with its one created book unticked: the book is
// deleted rather than promoted, so no enrichment job reaches the dev queue.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let importId: number;

test.describe("Books admin — Goodreads imports", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    rails("e2e:goodreads_import_cleanup");
    const lines = rails("e2e:goodreads_import_seed").trim().split("\n");
    importId = JSON.parse(lines[lines.length - 1]).import_id;
  });

  test.afterAll(() => {
    rails("e2e:goodreads_import_cleanup");
  });

  test("an admin unticks the created book and approves the import", async ({ page }) => {
    await page.goto("/admin/goodreads_imports");
    const row = page.locator(`[data-testid="import-row"][data-import-id="${importId}"]`);
    await expect(row).toBeVisible();
    await row.getByRole("link").first().click();

    await expect(page).toHaveURL(new RegExp(`/admin/goodreads_imports/${importId}`));
    await page.getByRole("checkbox", { name: /keep/i }).first().uncheck();
    await page.getByRole("button", { name: "Approve" }).click();

    await expect(page.getByRole("alert")).toContainText("Approved");
    await expect(page.getByTestId("review-status")).toHaveText("Approved");
  });
});
