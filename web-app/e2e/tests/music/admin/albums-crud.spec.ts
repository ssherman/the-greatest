import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Albums', () => {
  test('index page loads with heading and table', async ({ albumsPage }) => {
    await albumsPage.goto();

    await expect(albumsPage.heading).toBeVisible();
    await expect(albumsPage.subtitle).toBeVisible();
    await expect(albumsPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ albumsPage }) => {
    await albumsPage.goto();

    await expect(albumsPage.searchInput).toBeVisible();
  });

  test('index page shows New Album button', async ({ albumsPage }) => {
    await albumsPage.goto();

    await expect(albumsPage.newAlbumButton).toBeVisible();
  });

  test('index page shows album rows', async ({ albumsPage }) => {
    await albumsPage.goto();

    const rowCount = await albumsPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking an album navigates to show page', async ({ albumsPage }) => {
    await albumsPage.goto();
    await albumsPage.clickFirstAlbum();

    await expect(albumsPage.page.getByTestId('back-button')).toBeVisible();
    await expect(albumsPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
