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

let seeded: Seeded;

test.beforeAll(() => {
  rails("e2e:book_submissions_cleanup");
  const lines = rails("e2e:book_submissions_seed").trim().split("\n");
  seeded = JSON.parse(lines[lines.length - 1]);
});

test.afterAll(() => {
  rails("e2e:book_submissions_cleanup");
});

test.describe("Books account: add a missing book", () => {
  test.describe.configure({ mode: "serial" });

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

// Everything below answers the strip, the submit endpoint and the search with
// page.route, so no submission ever reaches the server (and nothing is queued).
// The page itself is the real list page of the seeded Playwright user.
test.describe("Books account: add a missing book, network stubbed", () => {
  const search = (page: Page) => page.getByTestId("add-item-search").getByRole("searchbox");
  const dialogOf = (page: Page) => page.getByTestId("book-submission-dialog");
  const strip = (page: Page) => page.getByTestId("book-submission-strip");

  const cancelForm = (id: number) =>
    `<form class="button_to" method="post" action="/my/book-submissions/${id}/cancel" data-turbo-frame="book_submissions"><button class="btn btn-xs" type="submit">Cancel</button></form>`;
  const retryButton = (id: number, method: string, title = "", authors: string[] = []) =>
    `<button type="button" class="btn btn-xs" data-action="click->books--book-submissions#tryAnother" data-replaces="${id}" data-input-method="${method}" data-title="${title}" data-authors='${JSON.stringify(authors)}'>Try another way</button>`;
  const row = (id: number, text: string, buttons = "") =>
    `<div id="books_book_submission_${id}" data-testid="book-submission-row"><span>${text}</span><span>${buttons}</span></div>`;
  const frame = (rows: string, listId: number, inProgress = false, reload = false) =>
    `<turbo-frame id="book_submissions" target="_top"><div data-poll-url="/my/lists/${listId}/book-submissions"${inProgress ? ' data-in-progress="true"' : ""}${reload ? ' data-reload-list="true"' : ""} data-testid="book-submissions-state"></div>${rows}</turbo-frame>`;
  const html = (body: string, status = 200) => ({ status, contentType: "text/html", body });
  const stream = (body: string, status = 200) => ({ status, contentType: "text/vnd.turbo-stream.html", body });
  const acceptedStream = (rows: string, listId: number, inProgress = false) =>
    `<turbo-stream action="update" target="book-submission-errors"><template></template></turbo-stream>` +
    `<turbo-stream action="update" target="book-submission-hits"><template></template></turbo-stream>` +
    `<turbo-stream action="replace" target="book_submissions"><template>${frame(rows, listId, inProgress)}</template></turbo-stream>`;

  // GET answers come from `answer(n)` (n counts from 1); POSTs from `post`.
  async function stubStrip(page: Page, answer: (n: number) => ReturnType<typeof html>, post?: (n: number) => ReturnType<typeof html>) {
    const counts = { gets: 0, posts: 0 };
    await page.route("**/book-submissions", (route) => {
      if (route.request().method() === "GET") {
        counts.gets++;
        return route.fulfill(answer(counts.gets));
      }
      counts.posts++;
      return post ? route.fulfill(post(counts.posts)) : route.abort();
    });
    return counts;
  }

  async function stubSearch(page: Page, results: Array<{ text: string; value: number }> = []) {
    await page.route("**/listable_search*", (route) => route.fulfill({ json: results }));
  }

  async function open(page: Page) {
    await page.goto(`/my/lists/${seeded.list_id}`);
    await expect(strip(page)).toBeAttached();
  }

  test("a 502 on a poll keeps the rows, shows no Content missing and stops polling", async ({ page }) => {
    const listId = seeded.list_id;
    const counts = await stubStrip(page, (n) =>
      n === 1 ? html(frame(row(1, "Adding: Slow Book", cancelForm(1)), listId, true)) : html("<html><body>Bad Gateway</body></html>", 502)
    );
    await page.clock.install();
    await open(page);
    await expect(page.getByText("Adding: Slow Book")).toBeVisible();

    await page.clock.runFor(10_500);
    await expect.poll(() => counts.gets).toBe(2);
    await page.clock.runFor(30_000);
    await page.waitForTimeout(300);

    await expect(page.getByText("Adding: Slow Book")).toBeVisible();
    await expect(page.getByText("Content missing")).toHaveCount(0);
    expect(counts.gets).toBe(2);
  });

  test("a failed submit that is not a stream tells the reader and leaves the strip alone", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(page, () => html(frame(row(1, "Could not add X", retryButton(1, "goodreads")), listId)), () => html("<html>boom</html>", 500));
    await open(page);

    await page.getByRole("button", { name: "Try another way" }).click();
    const dialog = dialogOf(page);
    await dialog.locator("#book_submission_title").fill("A Title");
    await dialog.locator("#book_submission_authors_0").fill("An Author");
    await dialog.getByRole("button", { name: "Add book" }).click();

    await expect(dialog.locator("#book-submission-errors")).toContainText("Could not reach the server");
    await expect(page.getByText("Could not add X")).toBeVisible();
    await expect(page.getByText("Content missing")).toHaveCount(0);
  });

  test("ArrowDown while the first search is still pending reaches the footer and Enter opens the dialog", async ({ page }) => {
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await stubStrip(page, () => html(frame("", seeded.list_id)));
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => (release = resolve));
    await page.route("**/listable_search*", async (route) => {
      await gate;
      await route.fulfill({ json: [] });
    });
    await open(page);

    await search(page).fill("held search");
    await expect(page.getByTestId("add-missing-book")).toBeVisible();
    await search(page).press("ArrowDown");
    await search(page).press("Enter");

    await expect(dialogOf(page)).toBeVisible();
    expect(errors).toEqual([]);
    release();
  });

  test("each opening starts from its own details: nothing carries from one row to the next", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(page, () =>
      html(
        frame(
          row(1, "Could not add A", retryButton(1, "title_authors", "Title A", ["Ann", "Bo", "Cy"])) +
            row(3, "Could not add C", retryButton(3, "goodreads")),
          listId
        )
      )
    );
    await stubSearch(page);
    await open(page);
    const dialog = dialogOf(page);

    await page.getByRole("button", { name: "Try another way" }).first().click();
    await expect(dialog.locator("#book_submission_title")).toHaveValue("Title A");
    await expect(dialog.locator("input[name='book_submission[authors][]']")).toHaveCount(3);
    await page.keyboard.press("Escape");

    await page.getByRole("button", { name: "Try another way" }).last().click();
    await expect(dialog.getByRole("radio", { name: "Title and author" })).toBeChecked();
    await expect(dialog.locator("#book_submission_title")).toHaveValue("");
    await expect(dialog.locator("input[name='book_submission[authors][]']")).toHaveCount(1);
    await expect(dialog.locator("input[name='book_submission[authors][]']")).toHaveValue("");
    await page.keyboard.press("Escape");

    await search(page).fill("fresh search");
    await page.getByTestId("add-missing-book").click();
    await expect(dialog.getByRole("radio", { name: "Goodreads link" })).toBeChecked();
    await expect(dialog.locator("#book_submission_title")).toHaveValue("fresh search");
    await expect(dialog.locator("input[name='book_submission[authors][]']")).toHaveCount(1);
    await expect(dialog.locator("input[name='book_submission[authors][]']")).toHaveValue("");
  });

  test("after an accepted submission the search is cleared and the dropdown stays shut over the new row", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(
      page,
      () => html(frame("", listId)),
      () => stream(acceptedStream(row(7, "Adding: https://www.goodreads.com/book/show/7", cancelForm(7)), listId), 201)
    );
    await stubSearch(page);
    await open(page);

    await search(page).fill("The Dispossessed");
    await page.getByTestId("add-missing-book").click();
    await dialogOf(page).locator("#book_submission_goodreads_url").fill("https://www.goodreads.com/book/show/7");
    await dialogOf(page).getByRole("button", { name: "Add book" }).click();

    await expect(dialogOf(page)).toBeHidden();
    await expect(page.getByText("Adding: https://www.goodreads.com/book/show/7")).toBeVisible();
    await expect(search(page)).toHaveValue("");
    await expect(page.locator(".autocomplete-container ul")).toBeHidden();
    await page.getByTestId("book-submission-row").getByRole("button", { name: "Cancel" }).click({ trial: true });
  });

  test("Escape returns focus to the search without reopening the dropdown", async ({ page }) => {
    await stubStrip(page, () => html(frame("", seeded.list_id)));
    await stubSearch(page);
    await open(page);

    await search(page).fill("an unfinished thought");
    await page.getByTestId("add-missing-book").click();
    await expect(dialogOf(page)).toBeVisible();
    await page.keyboard.press("Escape");

    await expect(search(page)).toBeFocused();
    await page.waitForTimeout(700);
    await expect(page.locator(".autocomplete-container ul")).toBeHidden();
  });

  test("polling starts again after a submission once the 10 minute cap has passed", async ({ page }) => {
    const listId = seeded.list_id;
    const inProgress = frame(row(1, "Adding: Slow Book", cancelForm(1)) + row(2, "Could not add X", retryButton(2, "goodreads")), listId, true);
    const counts = await stubStrip(
      page,
      () => html(inProgress),
      () => stream(acceptedStream(row(9, "Adding: New Book", cancelForm(9)), listId, true), 201)
    );
    await page.clock.install();
    await open(page);
    for (let i = 0; i < 62; i++) {
      await page.clock.runFor(10_000);
      await page.waitForTimeout(120);
    }
    const stopped = counts.gets;
    await page.clock.runFor(30_000);
    await page.waitForTimeout(300);
    expect(counts.gets).toBe(stopped);

    await page.getByRole("button", { name: "Try another way" }).click();
    await dialogOf(page).locator("#book_submission_title").fill("A Title");
    await dialogOf(page).locator("#book_submission_authors_0").fill("An Author");
    await dialogOf(page).getByRole("button", { name: "Add book" }).click();
    await expect(page.getByText("Adding: New Book")).toBeVisible();
    await page.clock.runFor(10_500);
    await expect.poll(() => counts.gets).toBeGreaterThan(stopped);
  });

  test("a poll that changes nothing swaps nothing, keeps focus and announces nothing", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(page, () => html(frame(row(1, "Adding: Slow Book", cancelForm(1)), listId, true)));
    await page.clock.install();
    await open(page);
    const cancel = page.getByTestId("book-submission-row").getByRole("button", { name: "Cancel" });
    await cancel.focus();
    await page.evaluate(() => {
      (window as any).__mutations = 0;
      new MutationObserver((records) => ((window as any).__mutations += records.length)).observe(
        document.querySelector('[data-testid="book-submission-strip"]')!,
        { childList: true, subtree: true, characterData: true }
      );
    });

    await page.clock.runFor(10_500);
    await page.waitForTimeout(400);

    await expect(cancel).toBeFocused();
    expect(await page.evaluate(() => (window as any).__mutations)).toBe(0);
  });

  test("a poll that changes the rows keeps the focused button's place", async ({ page }) => {
    const listId = seeded.list_id;
    const counts = await stubStrip(page, (n) =>
      n === 1
        ? html(frame(row(1, "Adding: Slow Book", cancelForm(1)) + row(2, "Adding: Other", cancelForm(2)), listId, true))
        : html(frame(row(1, "Adding: Slow Book", cancelForm(1)) + row(2, "Adding: Other", cancelForm(2)) + row(3, "Added Fresh"), listId, true))
    );
    await page.clock.install();
    await open(page);
    await page.locator("#books_book_submission_2").getByRole("button", { name: "Cancel" }).focus();

    await page.clock.runFor(10_500);
    await expect.poll(() => counts.gets).toBe(2);
    await expect(page.getByText("Added Fresh")).toBeVisible();

    await expect(page.locator("#books_book_submission_2").getByRole("button", { name: "Cancel" })).toBeFocused();
  });

  test("after an accepted Try another way focus is somewhere that survives the replaced row", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(
      page,
      () => html(frame(row(1, "Could not add X", retryButton(1, "goodreads")), listId)),
      () => stream(acceptedStream(row(5, "Adding: Y", cancelForm(5)), listId), 201)
    );
    await open(page);
    await page.getByRole("button", { name: "Try another way" }).click();
    await dialogOf(page).locator("#book_submission_title").fill("A Title");
    await dialogOf(page).locator("#book_submission_authors_0").fill("An Author");
    await dialogOf(page).getByRole("button", { name: "Add book" }).click();

    await expect(page.getByText("Adding: Y")).toBeVisible();
    await expect(strip(page)).toBeFocused();
  });

  test("search results are never parsed as markup, and selection keeps the raw text", async ({ page }) => {
    // An <img> with a relative src makes a request the moment it is parsed, even
    // if the element is replaced a moment later, so counting requests tells
    // parsing from display.
    let probes = 0;
    await page.route("**/t9-probe.png", (route) => {
      probes++;
      return route.fulfill({ status: 200, contentType: "image/png", body: "" });
    });
    await stubStrip(page, () => html(frame("", seeded.list_id)));
    // Choosing a result runs the real add-item flow; it must not reach the server.
    await page.route("**/user_lists/*/items", (route) =>
      route.fulfill({ status: 422, contentType: "application/json", body: JSON.stringify({ error: { message: "stubbed" } }) })
    );
    await stubSearch(page, [
      { text: '<img src="/t9-probe.png"> marker title', value: 41 },
      { text: 12345 as unknown as string, value: 42 },
    ]);
    await open(page);

    await search(page).fill("marker");
    const items = page.locator(".autocomplete-container ul li[role='option']");
    await expect(items.first()).toHaveText('<img src="/t9-probe.png"> marker title');
    await page.waitForTimeout(500);
    expect(probes).toBe(0);
    await expect(page.locator(".autocomplete-container ul img")).toHaveCount(0);

    await search(page).press("ArrowDown");
    await expect(items.first()).toHaveAttribute("aria-selected", "true");
    await search(page).press("Enter");
    await expect(search(page)).toHaveValue('<img src="/t9-probe.png"> marker title');

    // A numeric title still works.
    await search(page).fill("12");
    await expect(items.first()).toHaveText("12345");
  });

  test("polls every 10 seconds, stops at 10 minutes", async ({ page }) => {
    const counts = await stubStrip(page, () => html(frame(row(1, "Adding: Slow Book", cancelForm(1)), seeded.list_id, true)));
    await page.clock.install();
    await open(page);
    expect(counts.gets).toBe(1);
    await page.clock.runFor(9_000);
    await page.waitForTimeout(150);
    expect(counts.gets).toBe(1);
    await page.clock.runFor(1_500);
    await expect.poll(() => counts.gets).toBe(2);

    for (let i = 0; i < 62; i++) {
      await page.clock.runFor(10_000);
      await page.waitForTimeout(120);
    }
    const stopped = counts.gets;
    expect(stopped).toBeLessThanOrEqual(62);
    await page.clock.runFor(60_000);
    await page.waitForTimeout(300);
    expect(counts.gets).toBe(stopped);
  });

  test("a reload-list answer reloads the list once, not again when the controller reconnects", async ({ page }) => {
    let listLoads = 0;
    await page.route(new RegExp(`/my/lists/${seeded.list_id}(\\?.*)?$`), (route) => {
      if (route.request().headers()["turbo-frame"] === "list_items") listLoads++;
      return route.continue();
    });
    await stubStrip(page, (n) => html(frame("", seeded.list_id, false, n === 1)));
    await page.goto(`/my/lists/${seeded.list_id}`);
    await expect.poll(() => listLoads).toBe(1);
    // What a Turbo cache restore does to the element: take it out and put it back.
    await page.evaluate(() => {
      const wrapper = document.querySelector('[data-testid="book-submission-strip"]')!;
      const parent = wrapper.parentElement!;
      wrapper.remove();
      parent.appendChild(wrapper);
    });
    await page.waitForTimeout(1_200);
    expect(listLoads).toBe(1);
  });

  test("a refusal that is only a toast also shows inside the open dialog, and reopening starts clean", async ({ page }) => {
    const listId = seeded.list_id;
    await stubStrip(
      page,
      () => html(frame("", listId)),
      () =>
        stream(
          `<turbo-stream action="append" target="toast-region"><template><div class="alert alert-error" role="status"><span>You are going too fast. Wait a minute and try again</span></div></template></turbo-stream>`,
          429
        )
    );
    await stubSearch(page);
    await open(page);
    await search(page).fill("anything");
    await page.getByTestId("add-missing-book").click();
    const dialog = dialogOf(page);
    await dialog.locator("#book_submission_goodreads_url").fill("https://www.goodreads.com/book/show/1");
    await dialog.getByRole("button", { name: "Add book" }).click();
    await expect(dialog.locator("#book-submission-errors")).toContainText("too fast");

    await page.keyboard.press("Escape");
    await search(page).fill("anything else");
    await page.getByTestId("add-missing-book").click();
    await expect(dialog.locator("#book-submission-errors")).toBeEmpty();
    await expect(dialog.getByTestId("book-submission-hits")).toBeEmpty();
    await expect(dialog.locator("#book-submission-replaces")).toBeDisabled();
  });
});
