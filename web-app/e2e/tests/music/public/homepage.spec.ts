import { test, expect } from '../../../fixtures/auth';

test.describe('Music Homepage', () => {
  test('displays hero section with branding', async ({ homePage }) => {
    await homePage.goto();

    await expect(homePage.heading).toBeVisible();
    await expect(homePage.subtitle).toBeVisible();
  });

  test('displays hero call-to-action links', async ({ homePage }) => {
    await homePage.goto();

    await expect(homePage.topAlbumsLink).toBeVisible();
    await expect(homePage.topSongsLink).toBeVisible();
    await expect(homePage.topArtistsLink).toBeVisible();
  });

  test('displays featured albums section', async ({ homePage }) => {
    await homePage.goto();

    await expect(homePage.topAlbumsHeading).toBeVisible();
    // Verify at least one album card is rendered
    await expect(homePage.page.locator('.card', { has: homePage.page.locator('.badge', { hasText: '#1' }) }).first()).toBeVisible();
  });

  test('displays featured songs section', async ({ homePage }) => {
    await homePage.goto();

    await expect(homePage.topSongsHeading).toBeVisible();
    // Verify at least one song row is rendered
    await expect(homePage.page.locator('table tbody tr').first()).toBeVisible();
  });
});
