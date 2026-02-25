import { test, expect } from '@playwright/test';

test.describe('Game Detail Page', () => {
  test('game show page loads with title and metadata', async ({ page }) => {
    // Navigate to ranked games first to find a game link
    await page.goto('/video-games');

    // Click the first game card's title link to navigate to its show page
    const firstGameCard = page.locator('.card').first();
    await expect(firstGameCard).toBeVisible();
    await firstGameCard.locator('.card-title a').click();

    // Verify show page loaded with game title
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();

    // Verify release year badge is shown
    await expect(page.locator('text=Released:').first()).toBeVisible();
  });

  test('game show page displays developer byline', async ({ page }) => {
    await page.goto('/video-games');

    const firstGameCard = page.locator('.card').first();
    await firstGameCard.locator('.card-title a').click();

    // Verify "by" developer byline is present on the show page (not the card component)
    await expect(page.locator('p', { hasText: /by \w/ }).first()).toBeVisible();
  });

  test('game show page accessible via direct URL', async ({ page }) => {
    // Navigate directly to a game show page by slug
    await page.goto('/video-games');

    // Get the href of the first game card's title link
    const firstGameLink = page.locator('.card .card-title a').first();
    const href = await firstGameLink.getAttribute('href');
    expect(href).toContain('/game/');

    // Navigate directly to it
    await page.goto(href!);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('ranked game shows ranking blurb', async ({ page }) => {
    await page.goto('/video-games');

    const firstGameCard = page.locator('.card').first();
    await firstGameCard.locator('.card-title a').click();

    // Verify ranking blurb is shown
    await expect(page.locator('text=/greatest video game of all time/')).toBeVisible();
  });
});
