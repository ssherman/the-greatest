import { test, expect } from '@playwright/test';

test.describe('books admin dashboard', () => {
  test('loads with books branding and entity counts', async ({ page }) => {
    await page.goto('/admin');

    await expect(page).toHaveTitle(/The Greatest Books/);
    await expect(page.getByRole('heading', { name: 'Welcome to Books Admin' })).toBeVisible();

    await expect(page.getByTestId('stat-card-books')).toBeVisible();
    await expect(page.getByTestId('stat-card-authors')).toBeVisible();
    await expect(page.getByTestId('stat-card-editions')).toBeVisible();
    await expect(page.getByTestId('stat-card-series')).toBeVisible();
    await expect(page.getByTestId('stat-card-categories')).toBeVisible();
    await expect(page.getByTestId('stat-card-lists')).toBeVisible();
  });

  test('sidebar shows books branding and the global section only', async ({ page }) => {
    await page.goto('/admin');

    const sidebar = page.getByTestId('admin-sidebar');
    await expect(sidebar).toBeVisible();
    await expect(sidebar.getByRole('heading', { name: 'The Greatest Books' })).toBeVisible();

    await expect(sidebar.getByRole('link', { name: 'Books', exact: true })).toBeVisible();
    await expect(sidebar.getByRole('link', { name: 'Penalties' })).toBeVisible();
    await expect(sidebar.getByRole('link', { name: 'Users' })).toBeVisible();

    await expect(sidebar.getByRole('link', { name: 'Albums' })).toHaveCount(0);
    await expect(sidebar.getByRole('link', { name: 'Games' })).toHaveCount(0);
  });
});
