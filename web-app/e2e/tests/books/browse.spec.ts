import { test, expect } from '@playwright/test';

test.describe('Books browse pages', () => {
  test('a genre card navigates to its filter page', async ({ page }) => {
    await page.goto('/genres');

    const card = page.locator("a[href^='/the-greatest/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('a country card navigates to its filter page', async ({ page }) => {
    await page.goto('/countries');

    const card = page.locator("a[href*='written-by/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('the type toggle switches which categories are listed', async ({ page }) => {
    await page.goto('/genres');
    const before = await page.locator("a[href^='/the-greatest/']").first().getAttribute('href');

    await page.getByRole('link', { name: 'Subjects' }).click();

    await expect(page).toHaveURL(/filter=subject/);
    expect(await page.locator("a[href^='/the-greatest/']").first().getAttribute('href')).not.toBe(before);
  });

  test('the footer links reach both browse pages', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('contentinfo').getByRole('link', { name: 'Genres' }).click();
    await expect(page).toHaveURL('/genres');

    await page.goto('/');

    await page.getByRole('contentinfo').getByRole('link', { name: 'Origins' }).click();
    await expect(page).toHaveURL('/countries');
  });

  test('the filter pane links out to the browse page', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.getByRole('button', { name: /Category/ }).click();

    await page.getByRole('link', { name: /Browse all genres/ }).click();

    await expect(page).toHaveURL('/genres');
  });
});
