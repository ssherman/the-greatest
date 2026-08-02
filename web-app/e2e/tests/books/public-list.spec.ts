import { test, expect } from '@playwright/test';

const publicId = process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID!;
const privateId = process.env.PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID!;

test.describe('Public books user list', () => {
  test('an anonymous visitor can read a public list', async ({ page }) => {
    const response = await page.goto(`/my/lists/${publicId}`);

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'E2E Public Books', level: 1 })).toBeVisible();
    await expect(page.getByTestId('list-item-count')).toBeVisible();
  });

  test('an anonymous visitor sees no add box and no My Lists backlink', async ({ page }) => {
    await page.goto(`/my/lists/${publicId}`);

    await expect(page.getByTestId('add-item-search')).toHaveCount(0);
    await expect(page.getByTestId('back-to-lists')).toHaveCount(0);
  });

  test('a public list is noindex', async ({ page }) => {
    await page.goto(`/my/lists/${publicId}`);

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
  });

  test('the legacy /user_lists/:id alias resolves for a public list', async ({ page }) => {
    const response = await page.goto(`/user_lists/${publicId}`);

    expect(response?.status()).toBe(200);
  });

  test('a private list 404s for an anonymous visitor', async ({ page }) => {
    const response = await page.goto(`/my/lists/${privateId}`);

    expect(response?.status()).toBe(404);
  });

  test('the legacy /user_lists index 301s to /my/lists', async ({ request }) => {
    // Asserted at the HTTP level, not via page.goto: /my/lists then bounces an
    // anonymous visitor to /, so the browser's final URL is not the redirect target.
    const response = await request.get('/user_lists', { maxRedirects: 0 });

    expect(response.status()).toBe(301);
    expect(response.headers()['location']).toContain('/my/lists');
  });
});
