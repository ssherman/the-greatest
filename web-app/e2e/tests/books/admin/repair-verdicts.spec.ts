import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Seeds a proposed relink and a proposed re-import match through a rake
// helper. The relink is found with the kind filter, opened and rejected; the
// match is corrected to another book. Neither changes catalog data: a rejected
// verdict is never applied, and the seeded match names no edition, so an apply
// run passes it by.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let verdictId: number;
let matchVerdictId: number;
let rightBookId: number;

test.describe("Books admin — repair verdicts", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    const lines = rails("e2e:repair_verdicts_seed").trim().split("\n");
    const seeded = JSON.parse(lines[lines.length - 1]);
    verdictId = seeded.verdict_id;
    matchVerdictId = seeded.match_verdict_id;
    rightBookId = seeded.right_book_id;
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

  test("correcting a re-import match to the right book approves it on that book", async ({ page }) => {
    await page.goto(`/admin/repair_verdicts/${matchVerdictId}`);
    const form = page.getByTestId("correct-form");
    await form.getByLabel("Right book id").fill(String(rightBookId));
    await form.getByRole("button", { name: "Use this book" }).click();

    await expect(page.getByRole("alert")).toContainText("Corrected and approved");
    await expect(page.getByTestId("verdict-status")).toHaveText("Approved");
    await expect(page.getByTestId("correct-form")).toHaveCount(1);
  });
});
