import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Companies', () => {
  test('index page loads with heading and table', async ({ companiesPage }) => {
    await companiesPage.goto();

    await expect(companiesPage.heading).toBeVisible();
    await expect(companiesPage.subtitle).toBeVisible();
    await expect(companiesPage.table).toBeVisible();
  });

  test('index page shows search input', async ({ companiesPage }) => {
    await companiesPage.goto();

    await expect(companiesPage.searchInput).toBeVisible();
  });

  test('index page shows New Company button', async ({ companiesPage }) => {
    await companiesPage.goto();

    await expect(companiesPage.newCompanyButton).toBeVisible();
  });

  test('index page shows company rows', async ({ companiesPage }) => {
    await companiesPage.goto();

    const rowCount = await companiesPage.tableRows.count();
    expect(rowCount).toBeGreaterThan(0);
  });

  test('clicking a company navigates to show page', async ({ companiesPage }) => {
    await companiesPage.goto();
    await companiesPage.clickFirstCompany();

    await expect(companiesPage.page.getByTestId('back-button')).toBeVisible();
    await expect(companiesPage.page.getByRole('link', { name: 'Edit' })).toBeVisible();
  });
});
