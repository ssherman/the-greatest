import { test, expect } from '@playwright/test';

test.describe('Greatest authors', () => {
  test('the index lists ranked authors', async ({ page }) => {
    await page.goto('/authors');

    await expect(page.getByRole('heading', { level: 1, name: /Greatest Authors/i })).toBeVisible();
    await expect(page.locator('ol > li').first()).toBeVisible();
  });

  test('an index row links through to the author page', async ({ page }) => {
    await page.goto('/authors');

    const firstAuthorLink = page.locator('ol > li h2 a').first();
    const name = (await firstAuthorLink.textContent())?.trim() ?? '';
    await firstAuthorLink.click();

    await expect(page).toHaveURL(/\/author\//);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
  });

  test('the author page shows a rank badge and ranked books', async ({ page }) => {
    await page.goto('/authors');
    await page.locator('ol > li h2 a').first().click();

    await expect(page.locator('.badge', { hasText: 'Ranked #' })).toBeVisible();
    await expect(page.getByRole('heading', { level: 2, name: 'Ranked books' })).toBeVisible();
  });

  test('the all books toggle navigates and back-links', async ({ page }) => {
    await page.goto('/authors');
    const authorLink = page.locator('ol > li h2 a').first();
    const name = (await authorLink.textContent())?.trim() ?? '';
    await authorLink.click();

    await page.getByRole('link', { name: 'All books' }).click();
    await expect(page).toHaveURL(/\/author\/[^/]+\/all-books$/);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
    await expect(page.getByRole('heading', { level: 2, name: 'All books' })).toBeVisible();

    await page.getByRole('link', { name: 'Ranked books' }).click();
    await expect(page).toHaveURL(/\/author\/[^/]+$/);
    await expect(page.getByRole('heading', { level: 2, name: 'Ranked books' })).toBeVisible();
  });

  test('index pagination works', async ({ page }) => {
    await page.goto('/authors/page/2');

    await expect(page.getByRole('heading', { level: 1, name: /Greatest Authors/i })).toBeVisible();
    await expect(page.getByText(/Page 2 of/)).toBeVisible();
  });

  test('page one redirects to the canonical index', async ({ page }) => {
    await page.goto('/authors/page/1');

    await expect(page).toHaveURL(/\/authors$/);
  });

  test('legacy /authors/:id redirects to the slug url', async ({ page }) => {
    await page.goto('/authors/4789');

    await expect(page).toHaveURL(/\/author\/[^/]+$/);
  });

  test('the Authors nav link reaches the index', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal').getByRole('link', { name: 'Authors', exact: true }).click();

    await expect(page).toHaveURL(/\/authors$/);
  });
});
