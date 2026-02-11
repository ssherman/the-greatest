import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Platforms', () => {
  test('index page loads with heading', async ({ platformsPage }) => {
    await platformsPage.goto();

    await expect(platformsPage.heading).toBeVisible();
    await expect(platformsPage.subtitle).toBeVisible();
  });

  test('index page shows search input', async ({ platformsPage }) => {
    await platformsPage.goto();

    await expect(platformsPage.searchInput).toBeVisible();
  });

  test('clicking a platform navigates to show page', async ({ platformsPage, page }) => {
    // Create a platform first to ensure there's data
    const name = `E2E Nav Platform ${Date.now()}`;
    await platformsPage.goto();
    await page.getByRole('link', { name: 'New Platform' }).first().click();
    await page.getByLabel(/Name/).fill(name);
    await page.getByLabel(/Platform Family/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Platform' }).click();
    await page.waitForURL(/\/admin\/platforms\//);

    // Go back to index and click the platform
    await platformsPage.goto();
    await platformsPage.tableRows.first().getByRole('link').first().click();

    await expect(page.getByTestId('back-button')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });

  test('create a new platform', async ({ platformsPage, page }) => {
    const uniqueName = `E2E Test Platform ${Date.now()}`;
    await platformsPage.goto();
    await page.getByRole('link', { name: 'New Platform' }).first().click();

    await expect(page).toHaveURL(/\/admin\/platforms\/new/);

    await page.getByLabel(/Name/).fill(uniqueName);
    await page.getByLabel(/Abbreviation/).fill('E2E');
    await page.getByLabel(/Platform Family/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Platform' }).click();

    await page.waitForURL(/\/admin\/platforms\//);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();
  });

  test('edit an existing platform', async ({ platformsPage, page }) => {
    // First create a platform to edit
    const originalName = `E2E Edit Platform ${Date.now()}`;
    await platformsPage.goto();
    await page.getByRole('link', { name: 'New Platform' }).first().click();
    await page.getByLabel(/Name/).fill(originalName);
    await page.getByLabel(/Platform Family/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Platform' }).click();
    await page.waitForURL(/\/admin\/platforms\//);

    // Now edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated Platform ${Date.now()}`;
    await page.getByLabel(/Name/).fill(updatedName);
    await page.getByRole('button', { name: 'Update Platform' }).click();

    await page.waitForURL(/\/admin\/platforms\//);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();
  });

  test('delete a platform', async ({ platformsPage, page }) => {
    // First create a platform to delete
    const platformName = `E2E Delete Platform ${Date.now()}`;
    await platformsPage.goto();
    await page.getByRole('link', { name: 'New Platform' }).first().click();
    await page.getByLabel(/Name/).fill(platformName);
    await page.getByLabel(/Platform Family/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Platform' }).click();
    await page.waitForURL(/\/admin\/platforms\//);

    // Handle the turbo_confirm dialog
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/platforms$/);
  });
});
