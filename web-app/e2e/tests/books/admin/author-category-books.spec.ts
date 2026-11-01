import { test, expect } from "@playwright/test";

// The read-only "Books" cards on the author and category admin pages. Both are
// lazy frames; book links must leave the frame and land on the book's admin page.
test.describe("Books admin — books on author and category pages", () => {
  test("an author's page lists their books and links to each book", async ({ page }) => {
    // war-and-peace is a seed-verified slug; its author is reached through it so
    // the test never lands on a bookless duplicate author record.
    await page.goto("/book/war-and-peace");
    const authorHref = await page.locator('a[href^="/author/"]').first().getAttribute("href");
    const authorSlug = authorHref!.replace("/author/", "");
    await page.goto(`/admin/authors/${authorSlug}`);
    await expect(page.getByText("Basic Information")).toBeVisible();

    // Lazy frames load only once scrolled into view.
    const frame = page.locator("turbo-frame#author_books_list");
    await frame.scrollIntoViewIfNeeded();
    await expect(frame.getByRole("link", { name: "War and Peace", exact: true })).toBeVisible();

    const firstBook = frame.locator("tbody tr").first().getByRole("link");
    const title = (await firstBook.textContent())!.trim();
    await firstBook.click();
    await expect(page).toHaveURL(/\/admin\/books\//);
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();
  });

  test("a big category pages its books inside the card", async ({ page }) => {
    await page.goto("/admin/categories?q=Fiction");
    await page.getByRole("link", { name: "Fiction", exact: true }).first().click();
    await expect(page.getByRole("heading", { name: "Fiction", level: 1 })).toBeVisible();

    const frame = page.locator("turbo-frame#category_books_list");
    await frame.scrollIntoViewIfNeeded();
    await expect(frame.locator("tbody tr")).toHaveCount(50);
    const firstOnPageOne = (await frame.locator("tbody tr").first().getByRole("link").textContent())!.trim();

    const showUrl = page.url();
    await frame.getByRole("link", { name: "2", exact: true }).click();
    await expect(frame.locator("tbody tr").first().getByRole("link")).not.toHaveText(firstOnPageOne);
    // Paging swaps only the card; the page itself stays put.
    expect(page.url()).toBe(showUrl);

    const book = frame.locator("tbody tr").first().getByRole("link");
    const title = (await book.textContent())!.trim();
    await book.click();
    await expect(page.getByRole("heading", { name: title, level: 1 })).toBeVisible();
  });
});
