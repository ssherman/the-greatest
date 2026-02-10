import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Platforms', () => {
  test('index page loads with heading and table', async ({ platformsPage }) => {
    await platformsPage.goto();

    await expect(platformsPage.heading).toBeVisible();
    await expect(platformsPage.subtitle).toBeVisible();
    await expect(platformsPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ platformsPage }) => {
    await platformsPage.goto();

    await expect(platformsPage.searchInput).toBeVisible();
  });

  test('index page shows New Platform button', async ({ platformsPage }) => {
    await platformsPage.goto();

    await expect(platformsPage.newPlatformButton).toBeVisible();
  });

  test('index page shows platform rows', async ({ platformsPage }) => {
    await platformsPage.goto();

    const rowCount = await platformsPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking a platform navigates to show page', async ({ platformsPage }) => {
    await platformsPage.goto();
    await platformsPage.clickFirstPlatform();

    await expect(platformsPage.page.getByTestId('back-button')).toBeVisible();
    await expect(platformsPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
