import { test, expect } from '../../../fixtures/auth';

test.describe('Music Rankings Page', () => {
  test('rankings page loads successfully', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: 'How Our Rankings Work' })).toBeVisible();
  });

  test('rankings page displays algorithm section', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: 'The Algorithm' })).toBeVisible();
  });

  test('rankings page displays stats section', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('heading', { name: 'By the Numbers' })).toBeVisible();
    await expect(page.getByText('Active Lists')).toBeVisible();
    await expect(page.getByText('Ranked Items')).toBeVisible();
  });

  test('rankings page displays open source links', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('link', { name: /weighted_list_rank/ }).first()).toBeVisible();
    await expect(page.getByRole('link', { name: /full site source/ }).first()).toBeVisible();
  });

  test('rankings page displays Discord sidebar card', async ({ page }) => {
    await page.goto('/rankings');

    await expect(page.getByRole('link', { name: 'Join us on Discord' })).toBeVisible();
  });
});
