import { test, expect } from '../../../fixtures/auth';

test.describe('Music Navigation', () => {
  test.beforeEach(async ({ homePage }) => {
    await homePage.goto();
  });

  test('navbar shows Albums dropdown that links to albums page', async ({ homePage }) => {
    await homePage.navAlbums.click();
    await homePage.page.getByRole('link', { name: 'All Time' }).first().click();

    await expect(homePage.page).toHaveURL(/\/albums/);
  });

  test('navbar shows Songs dropdown that links to songs page', async ({ homePage }) => {
    await homePage.navSongs.click();
    await homePage.page.getByRole('link', { name: 'All Time' }).first().click();

    await expect(homePage.page).toHaveURL(/\/songs/);
  });

  test('navbar Artists link navigates to artists page', async ({ homePage }) => {
    await homePage.navArtists.click();

    await expect(homePage.page).toHaveURL(/\/artists/);
  });

  test('navbar Lists link navigates to lists page', async ({ homePage }) => {
    await homePage.navLists.click();

    await expect(homePage.page).toHaveURL(/\/lists/);
  });

  test('hero Top Albums link navigates to albums page', async ({ homePage }) => {
    await homePage.topAlbumsLink.click();

    await expect(homePage.page).toHaveURL(/\/albums/);
  });

  test('hero Top Songs link navigates to songs page', async ({ homePage }) => {
    await homePage.topSongsLink.click();

    await expect(homePage.page).toHaveURL(/\/songs/);
  });

  test('hero Top Artists link navigates to artists page', async ({ homePage }) => {
    await homePage.topArtistsLink.click();

    await expect(homePage.page).toHaveURL(/\/artists/);
  });
});
