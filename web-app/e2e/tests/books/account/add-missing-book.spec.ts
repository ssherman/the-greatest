import { test, expect, type Page } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";
import { seed } from "../../../support/seed";

// "Can't find it? Add a book" on a books list page. Nothing here creates a real
// submission: no Sidekiq runs for the E2E server and a queued job would stay in
// the shared Redis. The spec drives rows the seed task made, the validation
// errors and the instant-check hit only (a book the seed gave a Goodreads id).
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) =>
  execSync(`bin/rails ${task}`, {
    cwd: WEB_APP,
    encoding: "utf8",
    env: { ...process.env, E2E_BOOK_SUBMISSIONS_EMAIL: seed().users.user.email },
  });

type Seeded = {
  list_id: number;
  hit_title: string;
  hit_goodreads_id: number;
  looking_up_id: number;
  needs_details_id: number;
  added_id: number;
};

test.describe("Books account: add a missing book", () => {
  test.describe.configure({ mode: "serial" });

  let seeded: Seeded;

  test.beforeAll(() => {
    rails("e2e:book_submissions_cleanup");
    const lines = rails("e2e:book_submissions_seed").trim().split("\n");
    seeded = JSON.parse(lines[lines.length - 1]);
  });

  test.afterAll(() => {
    rails("e2e:book_submissions_cleanup");
  });

  const search = (page: Page) => page.getByTestId("add-item-search").getByRole("searchbox");

  async function openList(page: Page) {
    await page.goto(`/my/lists/${seeded.list_id}`);
    await expect(page.getByTestId("book-submission-strip")).toBeVisible();
    await expect(page.getByTestId("book-submission-row").first()).toBeVisible();
  }

  test("the strip shows each seeded row and the owner sees Not yet reviewed", async ({ page }) => {
    await openList(page);
    const strip = page.getByTestId("book-submission-strip");

    await expect(strip.getByText("Adding: E2E Book Submission Looking Up")).toBeVisible();
    await expect(strip.getByText("We couldn't find a book from that link. Try another way")).toBeVisible();
    await expect(strip.getByText("Added E2E Book Submission Added")).toBeVisible();
    await expect(strip.getByRole("button", { name: "Try another way" })).toBeVisible();
    await expect(page.getByTestId("not-yet-reviewed").first()).toHaveText("Not yet reviewed");
  });

  test("the footer opens the dialog with the typed text, with no results too", async ({ page }) => {
    await openList(page);

    await search(page).fill("zzzqqq no such book");
    const footer = page.getByTestId("add-missing-book");
    await expect(footer).toBeVisible();
    await footer.click();

    const dialog = page.getByTestId("book-submission-dialog");
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("heading", { name: "Add a book that isn't on the site" })).toBeVisible();
    await dialog.getByLabel("Title and author").check();
    await expect(dialog.getByLabel("Title", { exact: true })).toHaveValue("zzzqqq no such book");
  });

  test("the footer is reachable by keyboard", async ({ page }) => {
    await openList(page);

    await search(page).fill("zzzqqq no such book");
    // The footer is there at once; the search then rebuilds the list, so wait for it.
    await expect(page.getByTestId("add-missing-book")).toBeVisible();
    await expect(page.getByText('No results found for "zzzqqq no such book"')).toBeVisible();
    await search(page).press("ArrowDown");
    await search(page).press("Enter");

    await expect(page.getByTestId("book-submission-dialog")).toBeVisible();
    // Escape closes it and focus goes back to where the reader was.
    await page.keyboard.press("Escape");
    await expect(page.getByTestId("book-submission-dialog")).toBeHidden();
    await expect(search(page)).toBeFocused();
  });

  test("switching the method shows only that method's fields", async ({ page }) => {
    await openList(page);
    await search(page).fill("anything at all");
    await page.getByTestId("add-missing-book").click();
    const dialog = page.getByTestId("book-submission-dialog");

    await expect(dialog.getByLabel("Goodreads link", { exact: true }).last()).toBeVisible();
    await expect(dialog.getByLabel("ISBN", { exact: true }).last()).toBeHidden();
    await dialog.getByRole("radio", { name: "ISBN" }).check();
    await expect(dialog.locator("#book_submission_isbn")).toBeVisible();
    await expect(dialog.locator("#book_submission_goodreads_url")).toBeHidden();
    await expect(dialog.locator("#book_submission_goodreads_url")).toBeDisabled();
    await dialog.getByRole("radio", { name: "Title and author" }).check();
    await expect(dialog.locator("#book_submission_title")).toBeVisible();
    await expect(dialog.locator("#book_submission_authors_0")).toBeVisible();
  });

  test("a link that is not a Goodreads book shows its error inside the dialog", async ({ page }) => {
    await openList(page);
    await search(page).fill("anything at all");
    await page.getByTestId("add-missing-book").click();
    const dialog = page.getByTestId("book-submission-dialog");

    await dialog.locator("#book_submission_goodreads_url").fill("https://example.com/not-a-book");
    await dialog.getByRole("button", { name: "Add book" }).click();

    await expect(dialog.getByRole("alert")).not.toBeEmpty();
    await expect(dialog).toBeVisible();
  });

  test("a book we already have is shown, and Add to list adds it through the add-item flow", async ({ page }) => {
    await openList(page);
    await search(page).fill("anything at all");
    await page.getByTestId("add-missing-book").click();
    const dialog = page.getByTestId("book-submission-dialog");

    await dialog
      .locator("#book_submission_goodreads_url")
      .fill(`https://www.goodreads.com/book/show/${seeded.hit_goodreads_id}`);
    await dialog.getByRole("button", { name: "Add book" }).click();

    const hits = dialog.getByTestId("book-submission-hits");
    await expect(hits.getByText("We already have this. Is it the one?")).toBeVisible();
    await expect(hits.getByText(seeded.hit_title)).toBeVisible();
    await hits.getByRole("button", { name: "Add to list" }).click();

    await expect(dialog).toBeHidden();
    await expect(page.locator("#list_items").getByText(seeded.hit_title).first()).toBeVisible();
  });

  test("cancel removes a row that has no book yet", async ({ page }) => {
    await openList(page);
    const row = page.getByTestId("book-submission-row").filter({ hasText: "Adding: E2E Book Submission Looking Up" });

    await row.getByRole("button", { name: "Cancel" }).click();

    await expect(row).toHaveCount(0);
  });

  test("Try another way reopens the dialog on another method", async ({ page }) => {
    await openList(page);
    const row = page.getByTestId("book-submission-row").filter({ hasText: "We couldn't find a book from that link" });

    await row.getByRole("button", { name: "Try another way" }).click();

    const dialog = page.getByTestId("book-submission-dialog");
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole("radio", { name: "Title and author" })).toBeChecked();
  });
});
