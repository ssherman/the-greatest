import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Games', () => {
  test('index page loads with heading', async ({ gamesPage }) => {
    await gamesPage.goto();

    await expect(gamesPage.heading).toBeVisible();
    await expect(gamesPage.subtitle).toBeVisible();
  });

  test('index page shows search input', async ({ gamesPage }) => {
    await gamesPage.goto();

    await expect(gamesPage.searchInput).toBeVisible();
  });

  test('index page shows New Game button', async ({ gamesPage }) => {
    await gamesPage.goto();

    // May appear in header or empty state — use first()
    await expect(gamesPage.page.getByRole('link', { name: 'New Game' }).first()).toBeVisible();
  });
});
