import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Series', () => {
  test('index page loads with heading and table', async ({ seriesPage }) => {
    await seriesPage.goto();

    await expect(seriesPage.heading).toBeVisible();
    await expect(seriesPage.subtitle).toBeVisible();
    await expect(seriesPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ seriesPage }) => {
    await seriesPage.goto();

    await expect(seriesPage.searchInput).toBeVisible();
  });

  test('index page shows New Series button', async ({ seriesPage }) => {
    await seriesPage.goto();

    await expect(seriesPage.newSeriesButton).toBeVisible();
  });

  test('index page shows series rows', async ({ seriesPage }) => {
    await seriesPage.goto();

    const rowCount = await seriesPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking a series navigates to show page', async ({ seriesPage }) => {
    await seriesPage.goto();
    await seriesPage.clickFirstSeries();

    await expect(seriesPage.page.getByTestId('back-button')).toBeVisible();
    await expect(seriesPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
