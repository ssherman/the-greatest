import { test, expect } from '@playwright/test';

// The site-styled 404 (ErrorsController + ErrorPages) and the users' favorites
// nav link, which shipped pointing at a legacy list id and 404'd -- the first
// bug a beta tester reported. Music and games share the same controller and
// template; test/controllers/errors_controller_test.rb covers them per domain.
test.describe('Books not-found page', () => {
  test('an unknown URL is a 404 inside the site layout, with search', async ({ page }) => {
    const response = await page.goto('/this-page-does-not-exist');

    expect(response?.status()).toBe(404);
    await expect(page.getByRole('heading', { name: "We couldn't find that page", level: 1 })).toBeVisible();
    // The site's own navbar, not the static fallback page.
    await expect(page.locator('.navbar-center summary', { hasText: 'Lists' })).toBeVisible();

    await page.getByRole('searchbox', { name: /^Search / }).fill('dickens');
    await page.getByRole('button', { name: 'Search', exact: true }).click();

    await expect(page).toHaveURL(/\/search\?q=dickens$/);
  });

  test('a missing list is a 404 inside the site layout', async ({ page }) => {
    const response = await page.goto('/lists/987654321');

    expect(response?.status()).toBe(404);
    await expect(page.getByRole('heading', { name: "We couldn't find that page", level: 1 })).toBeVisible();
  });

  test("the Lists menu's users' favorites link reaches the list", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/');
    const listsMenu = page
      .locator('.navbar-center details')
      .filter({ has: page.locator('summary', { hasText: 'Lists' }) });
    await listsMenu.locator('summary').click();

    await listsMenu.getByRole('link', { name: "Our Users' Favorite Books of All Time" }).click();

    await expect(page).toHaveURL(/\/lists\/\d+$/);
    await expect(page.getByRole('heading', { name: /Our Users' Favorite Books of All Time/, level: 1 })).toBeVisible();
  });

  test('the legacy favorites list URL redirects to the generated list', async ({ page }) => {
    await page.goto('/lists/463');

    await expect(page).toHaveURL(/\/lists\/\d+$/);
    expect(page.url()).not.toMatch(/\/lists\/463$/);
    await expect(page.getByRole('heading', { name: /Our Users' Favorite Books of All Time/, level: 1 })).toBeVisible();
  });
});
