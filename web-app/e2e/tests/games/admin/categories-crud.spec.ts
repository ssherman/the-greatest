import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Categories', () => {
  test('index page loads with heading', async ({ categoriesPage }) => {
    await categoriesPage.goto();

    await expect(categoriesPage.heading).toBeVisible();
    await expect(categoriesPage.subtitle).toBeVisible();
  });

  test('index page shows search input', async ({ categoriesPage }) => {
    await categoriesPage.goto();

    await expect(categoriesPage.searchInput).toBeVisible();
  });

  test('clicking a category navigates to show page', async ({ categoriesPage, page }) => {
    // Create a category first to ensure there's data
    const name = `E2E Nav Category ${Date.now()}`;
    await categoriesPage.goto();
    await page.getByRole('link', { name: 'New Category' }).first().click();
    await page.getByLabel(/Name/).fill(name);
    await page.getByLabel(/Category Type/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Category' }).click();
    await page.waitForURL(/\/admin\/categories\//);

    // Go back to index and click the category
    await categoriesPage.goto();
    await categoriesPage.tableRows.first().getByRole('link').first().click();

    await expect(page.getByTestId('back-button')).toBeVisible();
    await expect(page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });

  test('create a new category', async ({ categoriesPage, page }) => {
    const uniqueName = `E2E Test Category ${Date.now()}`;
    await categoriesPage.goto();
    await page.getByRole('link', { name: 'New Category' }).first().click();

    await expect(page).toHaveURL(/\/admin\/categories\/new/);

    await page.getByLabel(/Name/).fill(uniqueName);
    await page.getByLabel(/Category Type/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Category' }).click();

    await page.waitForURL(/\/admin\/categories\//);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();
  });

  test('edit an existing category', async ({ categoriesPage, page }) => {
    // First create a category to edit
    const originalName = `E2E Edit Category ${Date.now()}`;
    await categoriesPage.goto();
    await page.getByRole('link', { name: 'New Category' }).first().click();
    await page.getByLabel(/Name/).fill(originalName);
    await page.getByLabel(/Category Type/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Category' }).click();
    await page.waitForURL(/\/admin\/categories\//);

    // Now edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated Category ${Date.now()}`;
    await page.getByLabel(/Name/).fill(updatedName);
    await page.getByRole('button', { name: 'Update Category' }).click();

    await page.waitForURL(/\/admin\/categories\//);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();
  });

  test('delete a category', async ({ categoriesPage, page }) => {
    // First create a category to delete
    const categoryName = `E2E Delete Category ${Date.now()}`;
    await categoriesPage.goto();
    await page.getByRole('link', { name: 'New Category' }).first().click();
    await page.getByLabel(/Name/).fill(categoryName);
    await page.getByLabel(/Category Type/).selectOption({ index: 1 });
    await page.getByRole('button', { name: 'Create Category' }).click();
    await page.waitForURL(/\/admin\/categories\//);

    // Handle the turbo_confirm dialog (categories use soft delete)
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/categories$/);
  });
});
