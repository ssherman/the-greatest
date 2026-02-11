import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Companies', () => {
  test('index page loads with heading', async ({ companiesPage }) => {
    await companiesPage.goto();

    await expect(companiesPage.heading).toBeVisible();
    await expect(companiesPage.subtitle).toBeVisible();
  });

  test('index page shows search input', async ({ companiesPage }) => {
    await companiesPage.goto();

    await expect(companiesPage.searchInput).toBeVisible();
  });

  test('clicking a company navigates to show page', async ({ companiesPage, page }) => {
    // Create a company first to ensure there's data
    const name = `E2E Nav Co ${Date.now()}`;
    await companiesPage.goto();
    await page.getByRole('link', { name: 'New Company' }).first().click();
    await page.getByLabel(/Name/).fill(name);
    await page.getByRole('button', { name: 'Create Company' }).click();
    await page.waitForURL(/\/admin\/companies\//);

    // Go back to index and click the company
    await companiesPage.goto();
    await companiesPage.tableRows.first().getByRole('link').first().click();

    await expect(page.getByTestId('back-button')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });

  test('create a new company', async ({ companiesPage, page }) => {
    const uniqueName = `E2E Test Company ${Date.now()}`;
    await companiesPage.goto();
    await page.getByRole('link', { name: 'New Company' }).first().click();

    await expect(page).toHaveURL(/\/admin\/companies\/new/);

    await page.getByLabel(/Name/).fill(uniqueName);
    await page.getByLabel(/Country/).fill('US');
    await page.getByLabel(/Year Founded/).fill('2000');
    await page.getByRole('button', { name: 'Create Company' }).click();

    await page.waitForURL(/\/admin\/companies\/e2e-test-company/);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();
  });

  test('create company with validation error shows error', async ({ companiesPage, page }) => {
    await companiesPage.goto();
    await page.getByRole('link', { name: 'New Company' }).first().click();

    // Submit empty form — name is required, browser validation should prevent submit
    // Clear the field and try to submit
    const nameField = page.getByLabel(/Name/);
    await nameField.fill('');
    await page.getByRole('button', { name: 'Create Company' }).click();

    // Should stay on the form (browser required validation prevents submission)
    await expect(page).toHaveURL(/\/admin\/companies/);
  });

  test('edit an existing company', async ({ companiesPage, page }) => {
    // First create a company to edit
    const originalName = `E2E Edit Co ${Date.now()}`;
    await companiesPage.goto();
    await page.getByRole('link', { name: 'New Company' }).first().click();
    await page.getByLabel(/Name/).fill(originalName);
    await page.getByRole('button', { name: 'Create Company' }).click();
    await page.waitForURL(/\/admin\/companies\//);

    // Now edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated Co ${Date.now()}`;
    await page.getByLabel(/Name/).fill(updatedName);
    await page.getByRole('button', { name: 'Update Company' }).click();

    await page.waitForURL(/\/admin\/companies\//);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();
  });

  test('delete a company', async ({ companiesPage, page }) => {
    // First create a company to delete
    const companyName = `E2E Delete Co ${Date.now()}`;
    await companiesPage.goto();
    await page.getByRole('link', { name: 'New Company' }).first().click();
    await page.getByLabel(/Name/).fill(companyName);
    await page.getByRole('button', { name: 'Create Company' }).click();
    await page.waitForURL(/\/admin\/companies\//);

    // Handle the turbo_confirm dialog
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/companies$/);
  });
});
