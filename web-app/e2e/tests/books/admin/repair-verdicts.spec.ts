import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Seeds one proposed relink verdict through a rake helper, finds it with the
// kind filter, opens it and rejects it. Rejecting an unapplied verdict changes
// no catalog data, so this is safe against the development database. Never
// approves: approval is safe too, but an apply run would then act on it.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let verdictId: number;

test.describe("Books admin — repair verdicts", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    const lines = rails("e2e:repair_verdicts_seed").trim().split("\n");
    verdictId = JSON.parse(lines[lines.length - 1]).verdict_id;
  });

  test.afterAll(() => {
    rails("e2e:repair_verdicts_cleanup");
  });

  test("the queue filters to the seeded relink, and rejecting it moves it to Rejected", async ({ page }) => {
    const row = page.locator(`[data-testid="verdict-row"][data-verdict-id="${verdictId}"]`);

    await page.goto("/admin/repair_verdicts?kind=merge_books");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/repair_verdicts?kind=relink&decided_by=ai");
    await expect(row).toBeVisible();

    await row.getByRole("link").click();
    await expect(page).toHaveURL(new RegExp(`/admin/repair_verdicts/${verdictId}$`));
    await page.getByRole("button", { name: "Reject" }).click();
    await expect(page.getByRole("alert")).toContainText("Rejected.");
    await expect(page.getByTestId("verdict-status")).toHaveText("Rejected");

    await page.goto("/admin/repair_verdicts?kind=relink&status=rejected");
    await expect(row).toBeVisible();
  });
});
