import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Seeds one pending duplicate pair between two throwaway books, one of them marked as a mixed book the Goodreads
// re-import is emptying, then checks the queue hides the pair, "Show them" lists it and "Back to the queue" hides it
// again. Nothing is merged or dismissed; the cleanup removes the pair, the verdict and both books.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let pairId: number;

test.describe("Books admin — duplicates naming a mixed book", () => {
  test.beforeAll(() => {
    const lines = rails("e2e:rebuilding_pair_seed").trim().split("\n");
    pairId = JSON.parse(lines[lines.length - 1]).pair_id;
  });

  test.afterAll(() => {
    rails("e2e:rebuilding_pair_cleanup");
  });

  test("the pending queue hides the pair, Show them lists it, and Back to the queue hides it again", async ({ page }) => {
    const pair = page.locator(`[data-testid="pair-row"][data-pair-id="${pairId}"]`);

    await page.goto("/admin/duplicate_candidates");
    await expect(page.getByTestId("being-rebuilt-notice")).toBeVisible();
    await expect(pair).toHaveCount(0);

    await page.getByTestId("being-rebuilt-notice").getByRole("link", { name: "Show them" }).click();
    await expect(page).toHaveURL(/rebuilding=1/);
    await expect(pair).toBeVisible();

    await page.getByTestId("being-rebuilt-notice").getByRole("link", { name: "Back to the queue" }).click();
    await expect(page).not.toHaveURL(/rebuilding=1/);
    await expect(pair).toHaveCount(0);
  });
});
