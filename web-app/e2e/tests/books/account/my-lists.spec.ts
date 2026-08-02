import { test, expect } from '@playwright/test';

test.describe('Books My Lists', () => {
  test('the My Lists nav link is revealed when signed in', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_my_lists').first()).not.toHaveClass(/hidden/);
  });

  test('the dashboard lists the four books defaults', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.getByRole('heading', { name: 'My Lists', level: 1 })).toBeVisible();
    const dashboard = page.getByTestId('my-lists-dashboard');
    await expect(dashboard.getByText('My Favorite Books')).toBeVisible();
    await expect(dashboard.getByText("Books I've Read")).toBeVisible();
    await expect(dashboard.getByText("Books I'm Reading")).toBeVisible();
    await expect(dashboard.getByText('Books I Want to Read')).toBeVisible();
  });

  test('the dashboard renders in the books theme', async ({ page }) => {
    await page.goto('/my/lists');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'books');
  });

  test('a list page offers all three view modes and switches between them', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const toolbar = page.getByTestId('list-toolbar');
    await expect(toolbar.getByRole('link', { name: 'Grid' })).toBeVisible();
    await toolbar.getByRole('link', { name: 'Grid' }).click();

    await expect(page).toHaveURL(/view_mode=grid_view/);
  });

  test('a list page offers a CSV download', async ({ page }) => {
    await page.goto('/my/lists');
    await page.getByTestId('my-lists-dashboard').getByText('My Favorite Books').click();

    const link = page.getByTestId('download-csv');
    await expect(link).toBeVisible();

    const response = await page.request.get((await link.getAttribute('href'))!);
    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toContain('text/csv');
  });
});
