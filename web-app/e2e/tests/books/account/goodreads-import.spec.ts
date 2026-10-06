import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Uploads a one-row export whose only edition the seed already resolved, so
// a dev worker that picks the import up resolves it from the cache with no
// finder or AI call. Without a worker the import stays queued; the page is
// tested either way. Cleanup removes the upload and the seed.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

test.describe("Books account — Goodreads import", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    rails("e2e:goodreads_import_cleanup");
    rails("e2e:goodreads_import_seed");
  });

  test.afterAll(() => {
    rails("e2e:goodreads_import_cleanup");
  });

  test("a member uploads an export and lands on its summary", async ({ page }) => {
    await page.goto("/my/goodreads-import");
    await expect(page.getByRole("heading", { level: 1 })).toContainText("Goodreads");

    await page.locator('input[type="file"]').setInputFiles(path.join(WEB_APP, "e2e", "fixtures", "goodreads_export.csv"));
    await page.getByRole("button", { name: "Upload" }).click();

    await expect(page).toHaveURL(/\/my\/goodreads-import\/\d+$/);
    await expect(page.getByTestId("import-status")).toBeVisible();
    const summaryPath = new URL(page.url()).pathname;

    // The history lists the upload, linked to its summary.
    await page.goto("/my/goodreads-import");
    await expect(page.locator(`a[href="${summaryPath}"]`)).toBeVisible();
  });
});
