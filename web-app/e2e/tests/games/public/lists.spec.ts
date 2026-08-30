import { test, expect, type Page } from '@playwright/test';

// The index sorts newest first, and the auto-generated "Our Users' Favorite
// Games of All Time" list sits at the top with zero items until somebody
// favorites a game. Four tests here used to open `.card h3 a` first() and
// assert against whatever that was, so they broke the moment an empty list
// sorted above a populated one. Walk the index instead and stop at the first
// list that actually has games on it.
async function openPopulatedList(page: Page) {
  await page.goto('/lists');

  const hrefs = await page.locator('.card h3 a').evaluateAll((links) =>
    links.map((a) => (a as HTMLAnchorElement).getAttribute('href')).filter(Boolean) as string[]
  );

  for (const href of hrefs) {
    await page.goto(href);
    const hasGames = await page
      .locator('.grid div.card .card-title a')
      .first()
      .isVisible()
      .catch(() => false);
    if (hasGames) return;
  }

  throw new Error(`No list on /lists rendered any game cards (checked ${hrefs.length})`);
}

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
    await openPopulatedList(page);
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // Should show game cards (from CardComponent, scoped to the grid so the
    // WeightBreakdownComponent's own div.card above it can't satisfy this)
    const gameCards = page.locator('.grid div.card .card-title a');
    await expect(gameCards.first()).toBeVisible();
  });

  test('list show page game cards have rank badges', async ({ page }) => {
    await openPopulatedList(page);
    await expect(page).toHaveURL(/\/lists\/\d+/);

    // First game card should have a #1 rank badge
    await expect(page.locator('text=#1').first()).toBeVisible();
  });

  test('clicking a game card from list navigates to game show page', async ({ page }) => {
    await openPopulatedList(page);
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

    await expect(page.locator('nav.pagy').first()).toBeVisible();
  });

  test('the newest sort is reachable and keeps its state', async ({ page }) => {
    await page.goto('/lists');

    await page.getByRole('link', { name: 'Recently added' }).click();

    await expect(page).toHaveURL(/sort=newest/);
  });

  test('search narrows the results', async ({ page }) => {
    await page.goto('/lists');
    const unfilteredCount = await page.locator('.card h3 a').count();

    await page.goto('/lists?q=the');
    await expect(page.getByText(/matching/)).toBeVisible();
    const filteredCount = await page.locator('.card h3 a').count();

    expect(filteredCount).toBeLessThan(unfilteredCount);
  });

  test('page one redirects to the canonical path', async ({ page }) => {
    await page.goto('/lists/page/1');

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('the list page shows the full weight breakdown', async ({ page }) => {
    await openPopulatedList(page);

    await expect(page.getByRole('heading', { name: 'How good is this list?' })).toBeVisible();
    await expect(page.getByText('Base weight')).toBeVisible();
  });
});
