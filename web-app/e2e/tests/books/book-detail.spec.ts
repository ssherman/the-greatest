import { test, expect } from '@playwright/test';

test.describe('Book detail page', () => {
  test('a grid card links through to a book page', async ({ page }) => {
    await page.goto('/');

    const firstCardLink = page.locator('.card h2 a').first();
    const title = (await firstCardLink.textContent())?.trim() ?? '';
    await firstCardLink.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
  });

  test('legacy /books/:id redirects permanently to the slug url', async ({ page }) => {
    const response = await page.goto('/books/1');

    expect(response?.status()).toBe(200);
    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('legacy /items/:id redirects to the slug url', async ({ page }) => {
    await page.goto('/items/1');

    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('the author name links through to the author page', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const authorLink = page.locator('main a[href^="/author/"]').first();
    const name = (await authorLink.textContent())?.trim() ?? '';
    await authorLink.click();

    await expect(page).toHaveURL(/\/author\//);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
  });

  test('a category links through to that category\'s filtered list', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const categoryLink = page.locator('a[href^="/the-greatest/"]').first();
    const name = (await categoryLink.textContent())?.trim() ?? '';
    await categoryLink.click();

    await expect(page).toHaveURL(/\/the-greatest\/[^/]+\/books$/);
    // Case-insensitive: category names are stored as entered ("epic") while the
    // filtered page title-cases them ("The Greatest Epic Books of All Time").
    await expect(page.getByRole('heading', { level: 1 })).toContainText(
      new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'),
    );
  });

  test('the origin links through to the country-filtered list', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const originLink = page.locator("[data-testid='detail-origin'] a").first();
    await originLink.click();

    await expect(page).toHaveURL(/\/the-greatest-books\/written-by\/[^/]+\/authors$/);
  });

  // The Origin value sits directly above "Original language", which for many books
  // is the very same word rendered as plain text. Without an underline the two are
  // indistinguishable and nothing marks one as clickable.
  test('the origin reads as a link rather than as plain text', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const decoration = (selector: string) =>
      page
        .locator(selector)
        .first()
        .evaluate((node) => getComputedStyle(node).textDecorationLine);

    expect(await decoration("[data-testid='detail-origin'] a")).toBe('underline');
    expect(await decoration("[data-testid='detail-original-language'] dd")).toBe('none');
  });

  test('the details card lists the book metadata', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    const details = page.locator("[data-testid='book-details']");
    await expect(details).toBeVisible();
    await expect(details.getByText('Published')).toBeVisible();
    await expect(details.locator("[data-testid='detail-original-language']")).toContainText('Russian');
  });

  test('/the-greatest-books redirects to the root', async ({ page }) => {
    await page.goto('/the-greatest-books');

    await expect(page).toHaveURL(/thegreatestbooks\.org\/$/);
  });
});
