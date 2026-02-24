import { test, expect } from '@playwright/test';

test.describe('Games Navigation', () => {
  test('navbar has Games and Lists links', async ({ page }) => {
    await page.goto('/');

    // Desktop nav links
    await expect(page.getByRole('link', { name: 'Games' }).first()).toBeVisible();
    await expect(page.getByRole('link', { name: 'Lists' }).first()).toBeVisible();
  });

  test('Games link navigates to ranked games', async ({ page }) => {
    await page.goto('/lists');

    await page.getByRole('link', { name: 'Games' }).first().click();
    await expect(page).toHaveURL('/');
    await expect(page.getByRole('heading').first()).toBeVisible();
  });

  test('Lists link navigates to lists page', async ({ page }) => {
    await page.goto('/video-games');

    await page.getByRole('link', { name: 'Lists' }).first().click();
    await expect(page).toHaveURL('/lists');
    await expect(page.getByRole('heading', { name: /Greatest Video Game Lists/i })).toBeVisible();
  });
});
