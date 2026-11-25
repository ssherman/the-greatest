import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";
import { seed } from "../../../support/seed";

// The admin review queue for books readers asked for. It drives the rows
// e2e:book_submissions_seed made. It never approves or merges (approve plans
// enrichment jobs in the shared Redis, merge is permanent). It rejects the one
// seeded provisional book, which is a real write to the development database:
// the book has no Read-list entry, so no reading-goal page purge is queued, and
// the cleanup task removes the row (book gone or not) in afterAll.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) =>
  execSync(`bin/rails ${task}`, {
    cwd: WEB_APP,
    encoding: "utf8",
    env: { ...process.env, E2E_BOOK_SUBMISSIONS_EMAIL: seed().users.user.email },
  });

type Seeded = {
  needs_details_id: number;
  added_id: number;
  looking_up_id: number;
  added_book_id: number;
};

let seeded: Seeded;

test.beforeAll(() => {
  rails("e2e:book_submissions_cleanup");
  const lines = rails("e2e:book_submissions_seed").trim().split("\n");
  seeded = JSON.parse(lines[lines.length - 1]);
});

test.afterAll(() => {
  rails("e2e:book_submissions_cleanup");
});

test.describe("Books admin: book submissions", () => {
  test.describe.configure({ mode: "serial" });

  const row = (page: import("@playwright/test").Page, id: number) => page.locator(`#submission-${id}`);

  test("the needs review tab holds the seeded provisional book with its decisions", async ({ page }) => {
    await page.goto(`/admin/book_submissions?tab=needs_review&book_id=${seeded.added_book_id}`);

    const added = row(page, seeded.added_id);
    await expect(added.getByTestId("submission-title")).toHaveText("E2E Book Submission Added");
    await expect(added.getByText("Provisional", { exact: true })).toBeVisible();
    for (const name of ["Approve", "Merge", "Reject"]) {
      await expect(added.locator("summary", { hasText: name })).toBeVisible();
    }
    await expect(added.locator("summary", { hasText: "Supply details" })).toHaveCount(0);
    const link = added.getByTestId("source-link");
    await expect(link).toHaveAttribute("href", /^https:\/\/www\.goodreads\.com\/book\/show\/\d+$/);
    await expect(link).toHaveAttribute("rel", "noopener noreferrer");
    await expect(link).toHaveAttribute("target", "_blank");
  });

  test("the tabs filter by state and the counts are shown", async ({ page }) => {
    await page.goto("/admin/book_submissions?tab=needs_details");
    await expect(page.getByTestId("tab-needs-details")).toHaveAttribute("aria-selected", "true");
    const stuck = row(page, seeded.needs_details_id);
    await expect(stuck.getByTestId("submission-title")).toHaveText("E2E Book Submission Needs Details");
    await expect(stuck.locator("summary", { hasText: "Supply details" })).toBeVisible();
    await expect(stuck.locator("summary", { hasText: "Approve" })).toHaveCount(0);

    await page.getByTestId("tab-all").click();
    await expect(page).toHaveURL(/tab=all/);
    await expect(page.getByTestId("count-all")).not.toHaveText("0");

    // A row still being looked up is listed with nothing to do.
    const looking = row(page, seeded.looking_up_id);
    await expect(looking.getByTestId("submission-title")).toHaveText("E2E Book Submission Looking Up");
    await expect(looking.getByTestId("submission-actions")).toHaveCount(0);

    // An unknown tab falls back to the default.
    await page.goto("/admin/book_submissions?tab=nonsense");
    await expect(page.getByTestId("tab-needs-review")).toHaveAttribute("aria-selected", "true");
  });

  test("Copy prompt puts the review prompt on the clipboard, with no reader text", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await page.goto("/admin/book_submissions");

    await page.getByTestId("copy-agent-prompt").click();
    await expect(page.getByTestId("copy-agent-prompt")).toHaveText("Copied!");

    const text = await page.evaluate(() => navigator.clipboard.readText());
    expect(text).toContain("/api/mcp/admin");
    expect(text).toContain("claim_book_submissions");
    expect(text).not.toContain("E2E Book Submission");
  });

  test("the book page of a user-added book carries the badge linking to its submission", async ({ page }) => {
    await page.goto(`/admin/books/${seeded.added_book_id}`);
    await page.getByTestId("user-added-badge").click();

    await expect(page).toHaveURL(new RegExp(`book_id=${seeded.added_book_id}`));
    await expect(row(page, seeded.added_id)).toBeVisible();
  });

  test("a reject preview changes nothing; rejecting moves the row to Rejected", async ({ page }) => {
    await page.goto(`/admin/book_submissions?tab=needs_review&book_id=${seeded.added_book_id}`);
    const added = row(page, seeded.added_id);

    await added.locator("summary", { hasText: "Reject" }).click();
    await added.locator("details[data-action-name=reject] textarea[name=note]").fill("E2E: not a real book");
    await added.getByTestId("reject-preview").click();
    await expect(page.getByText(/Dry run: would delete/)).toBeVisible();
    await expect(row(page, seeded.added_id)).toBeVisible();

    // The preview answers in place with the form open and the note kept: nothing to retype.
    await expect(row(page, seeded.added_id).locator("details[data-action-name=reject] textarea[name=note]")).toHaveValue("E2E: not a real book");
    page.once("dialog", (dialog) => {
      expect(dialog.message()).toContain("E2E Book Submission Added");
      dialog.accept();
    });
    await row(page, seeded.added_id).getByTestId("reject-confirm").click();
    await expect(page.getByText(/Rejected\. .* is deleted\./)).toBeVisible();

    await page.goto("/admin/book_submissions?tab=rejected");
    const rejected = row(page, seeded.added_id);
    await expect(rejected.getByTestId("submission-review")).toHaveText("Rejected");
    await expect(rejected.getByText("E2E: not a real book")).toBeVisible();
    await expect(rejected.getByTestId("submission-actions")).toHaveCount(0);
  });
});
