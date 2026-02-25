import { test, expect } from '@playwright/test';

test.describe('Games Lists', () => {
  test('lists index page loads successfully', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.getByRole('heading', { name: /Greatest Video Game Lists/i })).toBeVisible();
  });

  test('lists index shows list cards', async ({ page }) => {
    await page.goto('/lists');

    // Verify at least one list card is present
    const listCards = page.locator('a.card');
    await expect(listCards.first()).toBeVisible();
  });

  test('clicking a list navigates to list show page', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('a.card').first();
    const listName = await firstListCard.locator('.card-title').textContent();
    await firstListCard.click();

    // Show page should have an h1 matching the list name
    await expect(page).toHaveURL(/\/lists\/\d+/);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('list show page displays metadata badges', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('a.card').first();
    await firstListCard.click();

    // Wait for show page
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Should show a "X games" badge on the show page
    await expect(page.locator('.badge', { hasText: /\d+ games/ }).first()).toBeVisible();
  });

  test('list show page displays game cards in grid', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('a.card').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Should show game cards (from CardComponent)
    const gameCards = page.locator('a.card');
    await expect(gameCards.first()).toBeVisible();
  });

  test('list show page game cards have rank badges', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('a.card').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // First game card should have a #1 rank badge
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('clicking a game card from list navigates to game show page', async ({ page }) => {
    await page.goto('/lists');

    // Navigate to the first list
    const firstListCard = page.locator('a.card').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Get the href of the first game card to verify it points to a game page
    const firstGameCard = page.locator('a.card').first();
    await expect(firstGameCard).toBeVisible();
    const href = await firstGameCard.getAttribute('href');
    expect(href).toContain('/game/');

    // Click the game card and verify navigation
    await firstGameCard.click();
    await expect(page).toHaveURL(/\/game\//);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });
});
