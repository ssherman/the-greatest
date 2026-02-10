import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Sidebar Navigation', () => {
  test.beforeEach(async ({ dashboardPage }) => {
    await dashboardPage.goto();
  });

  const sidebar = (page: import('@playwright/test').Page) =>
    page.getByTestId('admin-sidebar');

  test('sidebar Artists link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Artists', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/artists/);
    await expect(page.getByRole('heading', { name: 'Artists', exact: true })).toBeVisible();
  });

  test('sidebar Albums link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Albums', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/albums/);
    await expect(page.getByRole('heading', { name: 'Albums', exact: true })).toBeVisible();
  });

  test('sidebar Songs link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Songs', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/songs/);
    await expect(page.getByRole('heading', { name: 'Songs', exact: true })).toBeVisible();
  });

  test('sidebar Categories link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Categories', exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/categories/);
  });

  test('sidebar Lists: Albums link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Lists: Albums' }).click();
    await expect(page).toHaveURL(/\/admin\/albums\/lists/);
  });

  test('sidebar Lists: Songs link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Lists: Songs' }).click();
    await expect(page).toHaveURL(/\/admin\/songs\/lists/);
  });

  test('sidebar Rankings: Album link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Rankings: Album' }).click();
    await expect(page).toHaveURL(/\/admin\/albums\/ranking_configurations/);
  });

  test('sidebar Rankings: Song link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Rankings: Song' }).click();
    await expect(page).toHaveURL(/\/admin\/songs\/ranking_configurations/);
  });

  test('sidebar Rankings: Artist link navigates correctly', async ({ page }) => {
    await sidebar(page).getByRole('link', { name: 'Rankings: Artist' }).click();
    await expect(page).toHaveURL(/\/admin\/artists\/ranking_configurations/);
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
