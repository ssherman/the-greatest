import { test, expect } from '@playwright/test';

test.describe('Books ranked grid', () => {
  test('root loads successfully', async ({ page }) => {
    const response = await page.goto('/');

    expect(response?.status()).toBe(200);
  });

  test('root renders the ranked grid heading', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: /Greatest Books/i, level: 1 })).toBeVisible();
  });

  test('root uses the books theme and declares a language', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'books');
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  });

  test('root is noindex until cutover', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
  });

  test('pagination links are path-based', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('nav.pagy a[href="/page/2"]').first()).toBeVisible();
  });

  test('page two loads and links back to the root, not /page/1', async ({ page }) => {
    await page.goto('/page/2');

    await expect(page.getByText(/Page 2 of/)).toBeVisible();
    await expect(page.locator('nav.pagy a[href="/page/1"]')).toHaveCount(0);
  });

  test('navbar exposes the login button', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_login_button')).toBeVisible();
  });
});
