import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Sidebar Navigation', () => {
  test.beforeEach(async ({ gamesDashboardPage }) => {
    await gamesDashboardPage.goto();
  });

  const sidebar = (page: import('@playwright/test').Page) =>
    page.getByTestId('admin-sidebar');

  test('sidebar Games link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Games', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/games/);
    await expect(page.getByRole('heading', { name: 'Games', exact: true })).toBeVisible();
  });

  test('sidebar Companies link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Companies', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/companies/);
    await expect(page.getByRole('heading', { name: 'Companies', exact: true })).toBeVisible();
  });

  test('sidebar Platforms link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Platforms', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/platforms/);
    await expect(page.getByRole('heading', { name: 'Platforms', exact: true })).toBeVisible();
  });

  test('sidebar Series link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Series', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/series/);
    await expect(page.getByRole('heading', { name: 'Series', exact: true })).toBeVisible();
  });

  test('sidebar Categories link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Categories', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/categories/);
    await expect(page.getByRole('heading', { name: 'Categories', exact: true })).toBeVisible();
  });

  test('sidebar Lists link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Lists', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/lists/);
    await expect(page.getByRole('heading', { name: 'Game Lists', exact: true })).toBeVisible();
  });

  test('sidebar Penalties link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Penalties' }).click();
    await expect(page).toHaveURL(/\/admin\/penalties/);
  });

  test('sidebar Users link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Users' }).click();
    await expect(page).toHaveURL(/\/admin\/users/);
  });
});
