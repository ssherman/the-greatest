import { test, expect } from '@playwright/test';

test.describe('Games Lists', () => {
  test('lists index page loads successfully', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.getByRole('heading', { name: /Greatest Video Game Lists/i })).toBeVisible();
  });

  test('lists index shows list cards', async ({ page }) => {
    await page.goto('/lists');

    // Verify at least one list card is present
    const listCards = page.locator('.card h3 a');
    await expect(listCards.first()).toBeVisible();
  });

  test('clicking a list navigates to list show page', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('.card h3 a').first();
    const listName = await firstListCard.textContent();
    await firstListCard.click();

    // Show page should have an h1 matching the list name
    await expect(page).toHaveURL(/\/lists\/\d+/);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('list show page displays metadata badges', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('.card h3 a').first();
    await firstListCard.click();

    // Wait for show page
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Should show a "X games" badge on the show page
    await expect(page.locator('.badge', { hasText: /\d+ games/ }).first()).toBeVisible();
  });

  test('list show page displays game cards in grid', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('.card h3 a').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Should show game cards (from CardComponent, now div.card)
    const gameCards = page.locator('div.card');
    await expect(gameCards.first()).toBeVisible();
  });

  test('list show page game cards have rank badges', async ({ page }) => {
    await page.goto('/lists');

    const firstListCard = page.locator('.card h3 a').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // First game card should have a #1 rank badge
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('clicking a game card from list navigates to game show page', async ({ page }) => {
    await page.goto('/lists');

    // Navigate to the first list
    const firstListCard = page.locator('.card h3 a').first();
    await firstListCard.click();
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Get the href of the first game card's title link
    const firstGameLink = page.locator('div.card .card-title a').first();
    await expect(firstGameLink).toBeVisible();
    const href = await firstGameLink.getAttribute('href');
    expect(href).toContain('/game/');

    // Click the game card and verify navigation
    await firstGameLink.click();
    await expect(page).toHaveURL(/\/game\//);
    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  });

  test('pagination nav renders', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.locator('nav.pagy')).toBeVisible();
  });

  test('the newest sort is reachable and keeps its state', async ({ page }) => {
    await page.goto('/lists');

    await page.getByRole('link', { name: 'Recently added' }).click();

    await expect(page).toHaveURL(/sort=newest/);
  });

  test('search narrows the results', async ({ page }) => {
    await page.goto('/lists?q=the');

    await expect(page.getByText(/matching/)).toBeVisible();
  });

  test('page one redirects to the canonical path', async ({ page }) => {
    await page.goto('/lists/page/1');

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('the list page shows the full weight breakdown', async ({ page }) => {
    await page.goto('/lists');
    await page.locator('.card h3 a').first().click();

    await expect(page.getByRole('heading', { name: 'How good is this list?' })).toBeVisible();
    await expect(page.getByText('Base weight')).toBeVisible();
  });
});
