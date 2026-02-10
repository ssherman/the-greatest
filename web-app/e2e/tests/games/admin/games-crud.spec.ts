import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Games', () => {
  test('index page loads with heading and table', async ({ gamesPage }) => {
    await gamesPage.goto();

    await expect(gamesPage.heading).toBeVisible();
    await expect(gamesPage.subtitle).toBeVisible();
    await expect(gamesPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ gamesPage }) => {
    await gamesPage.goto();

    await expect(gamesPage.searchInput).toBeVisible();
  });

  test('index page shows New Game button', async ({ gamesPage }) => {
    await gamesPage.goto();

    await expect(gamesPage.newGameButton).toBeVisible();
  });

  test('index page shows game rows', async ({ gamesPage }) => {
    await gamesPage.goto();

    const rowCount = await gamesPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking a game navigates to show page', async ({ gamesPage }) => {
    await gamesPage.goto();
    await gamesPage.clickFirstGame();

    await expect(gamesPage.page.getByTestId('back-button')).toBeVisible();
    await expect(gamesPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
