import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Merge', () => {
  test('merge button opens the modal on a game show page', async ({ gamesPage, page }) => {
    await gamesPage.goto();
    await gamesPage.tableRows.first().getByRole('link').first().click();
    await page.waitForURL(/\/admin\/games\/\d+|\/admin\/games\/[a-z0-9-]+/);

    await page.getByTestId('merge-game-button').click();

    await expect(page.getByRole('heading', { name: 'Merge Another Game Into This One' }))
      .toBeVisible();
    await expect(page.getByRole('button', { name: 'Merge Game' })).toBeVisible();
  });

  test('merge requires the confirmation checkbox', async ({ gamesPage, page }) => {
    await gamesPage.goto();
    await gamesPage.tableRows.first().getByRole('link').first().click();
    await page.waitForURL(/\/admin\/games\//);

    await page.getByTestId('merge-game-button').click();
    await page.getByRole('button', { name: 'Merge Game' }).click();

    // The checkbox is `required`, so the browser blocks submission and the modal stays open.
    await expect(page.getByRole('heading', { name: 'Merge Another Game Into This One' }))
      .toBeVisible();
  });
});
