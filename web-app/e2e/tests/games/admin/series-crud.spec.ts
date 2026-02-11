import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Series', () => {
  test('index page loads with heading', async ({ seriesPage }) => {
    await seriesPage.goto();

    await expect(seriesPage.heading).toBeVisible();
    await expect(seriesPage.subtitle).toBeVisible();
  });

  test('index page shows search input', async ({ seriesPage }) => {
    await seriesPage.goto();

    await expect(seriesPage.searchInput).toBeVisible();
  });

  test('clicking a series navigates to show page', async ({ seriesPage, page }) => {
    // Create a series first to ensure there's data
    const name = `E2E Nav Series ${Date.now()}`;
    await seriesPage.goto();
    await page.getByRole('link', { name: 'New Series' }).first().click();
    await page.getByLabel(/Name/).fill(name);
    await page.getByRole('button', { name: 'Create Series' }).click();
    await page.waitForURL(/\/admin\/series\//);

    // Go back to index and click the series
    await seriesPage.goto();
    await seriesPage.tableRows.first().getByRole('link').first().click();

    await expect(page.getByTestId('back-button')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });

  test('create a new series', async ({ seriesPage, page }) => {
    const uniqueName = `E2E Test Series ${Date.now()}`;
    await seriesPage.goto();
    await page.getByRole('link', { name: 'New Series' }).first().click();

    await expect(page).toHaveURL(/\/admin\/series\/new/);

    await page.getByLabel(/Name/).fill(uniqueName);
    await page.getByLabel(/Description/).fill('An E2E test series description');
    await page.getByRole('button', { name: 'Create Series' }).click();

    await page.waitForURL(/\/admin\/series\//);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();
  });

  test('edit an existing series', async ({ seriesPage, page }) => {
    // First create a series to edit
    const originalName = `E2E Edit Series ${Date.now()}`;
    await seriesPage.goto();
    await page.getByRole('link', { name: 'New Series' }).first().click();
    await page.getByLabel(/Name/).fill(originalName);
    await page.getByRole('button', { name: 'Create Series' }).click();
    await page.waitForURL(/\/admin\/series\//);

    // Now edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated Series ${Date.now()}`;
    await page.getByLabel(/Name/).fill(updatedName);
    await page.getByRole('button', { name: 'Update Series' }).click();

    await page.waitForURL(/\/admin\/series\//);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();
  });

  test('delete a series', async ({ seriesPage, page }) => {
    // First create a series to delete
    const seriesName = `E2E Delete Series ${Date.now()}`;
    await seriesPage.goto();
    await page.getByRole('link', { name: 'New Series' }).first().click();
    await page.getByLabel(/Name/).fill(seriesName);
    await page.getByRole('button', { name: 'Create Series' }).click();
    await page.waitForURL(/\/admin\/series\//);

    // Handle the turbo_confirm dialog
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/series$/);
  });
});
