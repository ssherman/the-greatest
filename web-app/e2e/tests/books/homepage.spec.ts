import { test, expect } from '@playwright/test';

test.describe('Books homepage', () => {
  test('homepage loads successfully', async ({ page }) => {
    const response = await page.goto('/');

    expect(response?.status()).toBe(200);
  });

  test('homepage has the books title', async ({ page }) => {
    await page.goto('/');

    await expect(page).toHaveTitle(/The Greatest Books/i);
  });

  test('homepage renders the placeholder hero', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: 'The Greatest Books', level: 1 })).toBeVisible();
  });

  test('homepage uses the cmyk theme', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'cmyk');
  });

  test('navbar exposes the login button', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_login_button')).toBeVisible();
  });
});
