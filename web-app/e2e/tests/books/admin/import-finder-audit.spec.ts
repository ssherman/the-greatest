import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Spec §15: seed one decision and one pair against two development books
// through a rake helper, exercise the filters, mark reviewed, dismiss the
// pair, drive both merge forms to the confirm gate and stop, then remove what
// was seeded. This spec NEVER performs a merge: it runs against the
// development database and a merge destroys a row with no undo. Both merge
// attempts below click Submit with the required checkbox unticked, so the
// browser blocks the form and the page never leaves.
//
// The seed runs `bin/rails e2e:import_finder_seed` from web-app, so this spec
// needs the same Ruby environment the dev server has. Idempotent: rerunning
// after a failed run resets the seeded rows.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let decisionId: number;
let pairId: number;

test.describe("Books admin — import finder audit", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    const lines = rails("e2e:import_finder_seed").trim().split("\n");
    const ids = JSON.parse(lines[lines.length - 1]);
    decisionId = ids.decision_id;
    pairId = ids.pair_id;
  });

  test.afterAll(() => {
    rails("e2e:import_finder_cleanup");
  });

  test("the decisions queue lists the seeded decision, filters it, stops a merge at the confirm gate, and marks it reviewed", async ({ page }) => {
    const row = page.locator(`[data-testid="decision-row"][data-decision-id="${decisionId}"]`);

    await page.goto("/admin/match_decisions");
    await expect(row).toBeVisible();

    // outcome=matched excludes an unmatched decision; the matching filter set keeps it.
    await page.goto("/admin/match_decisions?outcome=matched");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/match_decisions?outcome=unmatched&confidence=low&decided_by=ai&entity=book");
    await expect(row).toBeVisible();

    await row.getByRole("link").first().click();
    await expect(page).toHaveURL(new RegExp(`/admin/match_decisions/${decisionId}$`));
    await expect(page.locator('[data-testid="candidate-row"]')).toHaveCount(1);

    // Merge into candidate 1: the required checkbox blocks submission, so the URL does not change.
    const merge = page.getByTestId("merge-into-candidate");
    await merge.locator("summary").click();
    await merge.getByRole("button", { name: "Merge into #1" }).click();
    await expect(page).toHaveURL(new RegExp(`/admin/match_decisions/${decisionId}$`));

    await page.getByTestId("review-form").getByLabel("Review note").fill("E2E import finder audit spec");
    await page.getByRole("button", { name: "Mark reviewed" }).click();
    await expect(page.getByRole("alert")).toContainText("Marked reviewed.");

    await page.goto("/admin/match_decisions");
    await expect(row).toHaveCount(0);
    await page.goto("/admin/match_decisions?reviewed=reviewed");
    await expect(row).toBeVisible();
  });

  test("the duplicates queue lists the seeded pair, stops a merge at the confirm gate, and dismisses it", async ({ page }) => {
    const pair = page.locator(`[data-testid="pair-row"][data-pair-id="${pairId}"]`);

    await page.goto("/admin/duplicate_candidates");
    await expect(pair).toBeVisible();
    await expect(pair.locator('[data-testid="pair-side"]')).toHaveCount(2);

    const merge = pair.getByTestId("merge-a-into-b");
    await merge.locator("summary").click();
    await merge.getByRole("button", { name: "Merge A into B" }).click();
    await expect(page).toHaveURL(/\/admin\/duplicate_candidates$/);
    await expect(pair).toBeVisible();

    await pair.getByTestId("dismiss-form").getByPlaceholder("Why not a duplicate (optional)").fill("E2E import finder audit spec");
    await pair.getByRole("button", { name: "Not a duplicate" }).click();
    await expect(page.getByRole("alert")).toContainText("Marked as not a duplicate.");
    await expect(pair).toHaveCount(0);

    await page.goto("/admin/duplicate_candidates?status=not_duplicate");
    await expect(pair).toBeVisible();
  });
});
