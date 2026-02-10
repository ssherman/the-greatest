import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Artists', () => {
  test('index page loads with heading and table', async ({ artistsPage }) => {
    await artistsPage.goto();

    await expect(artistsPage.heading).toBeVisible();
    await expect(artistsPage.subtitle).toBeVisible();
    await expect(artistsPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ artistsPage }) => {
    await artistsPage.goto();

    await expect(artistsPage.searchInput).toBeVisible();
  });

  test('index page shows New Artist button', async ({ artistsPage }) => {
    await artistsPage.goto();

    await expect(artistsPage.newArtistButton).toBeVisible();
  });

  test('index page shows artist rows', async ({ artistsPage }) => {
    await artistsPage.goto();

    const rowCount = await artistsPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking an artist navigates to show page', async ({ artistsPage }) => {
    await artistsPage.goto();
    await artistsPage.clickFirstArtist();

    // Show page should have the back button and Edit button
    await expect(artistsPage.page.getByTestId('back-button')).toBeVisible();
    await expect(artistsPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
