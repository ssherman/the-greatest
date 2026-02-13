import { test, expect } from '../../../fixtures/games-auth';
import { type Page } from '@playwright/test';

async function deleteRankingConfiguration(page: Page) {
  // Assumes we're on the show page of the config to delete
  page.on('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Delete' }).click();
  await page.waitForURL(/\/admin\/ranking_configurations$/);
}

test.describe('Games Admin Ranking Configurations', () => {
  test('index page loads with heading', async ({ rankingConfigurationsPage }) => {
    await rankingConfigurationsPage.goto();

    await expect(rankingConfigurationsPage.heading).toBeVisible();
    await expect(rankingConfigurationsPage.newButton).toBeVisible();
  });

  test('index page shows New button', async ({ rankingConfigurationsPage }) => {
    await rankingConfigurationsPage.goto();

    await expect(rankingConfigurationsPage.newButton).toBeVisible();
  });

  test('create a new ranking configuration', async ({ rankingConfigurationsPage, page }) => {
    const uniqueName = `E2E Test Config ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await expect(page).toHaveURL(/\/admin\/ranking_configurations\/new/);

    await page.getByRole('textbox', { name: 'Name *' }).fill(uniqueName);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();

    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();

    // Cleanup
    await deleteRankingConfiguration(page);
  });

  test('read - show page displays config details', async ({ rankingConfigurationsPage, page }) => {
    const name = `E2E Read Config ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await page.getByRole('textbox', { name: 'Name *' }).fill(name);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);

    // Verify show page sections
    await expect(page.getByRole('heading', { name: name })).toBeVisible();
    await expect(page.getByText('Basic Information')).toBeVisible();
    await expect(page.getByText('Algorithm Configuration')).toBeVisible();
    await expect(page.getByText('Penalty Configuration')).toBeVisible();
    await expect(page.getByRole('heading', { name: /Ranked Items/ })).toBeVisible();
    await expect(page.getByRole('heading', { name: /Ranked Lists/ })).toBeVisible();

    // Cleanup
    await deleteRankingConfiguration(page);
  });

  test('update an existing configuration', async ({ rankingConfigurationsPage, page }) => {
    const originalName = `E2E Edit Config ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await page.getByRole('textbox', { name: 'Name *' }).fill(originalName);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);

    // Edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated Config ${Date.now()}`;
    await page.getByRole('textbox', { name: 'Name *' }).fill(updatedName);
    await page.getByRole('button', { name: 'Update Configuration' }).click();

    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();

    // Cleanup
    await deleteRankingConfiguration(page);
  });

  test('delete a configuration', async ({ rankingConfigurationsPage, page }) => {
    const configName = `E2E Delete Config ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await page.getByRole('textbox', { name: 'Name *' }).fill(configName);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);

    // Delete the config
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/ranking_configurations$/);
  });

  test('search filters the table', async ({ rankingConfigurationsPage, page }) => {
    // Create a config with a unique name for searching
    const searchName = `E2E Search ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await page.getByRole('textbox', { name: 'Name *' }).fill(searchName);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);

    // Go to index and search by URL param
    await page.goto(`/admin/ranking_configurations?q=${encodeURIComponent(searchName)}`);
    await expect(page.getByRole('link', { name: searchName })).toBeVisible();

    // Navigate to the config to clean up
    await page.getByRole('link', { name: searchName }).first().click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);
    await deleteRankingConfiguration(page);
  });

  test('show page displays action buttons', async ({ rankingConfigurationsPage, page }) => {
    const name = `E2E Actions Config ${Date.now()}`;
    await rankingConfigurationsPage.goto();
    await rankingConfigurationsPage.newButton.click();

    await page.getByRole('textbox', { name: 'Name *' }).fill(name);
    await page.getByRole('spinbutton', { name: 'Algorithm Version *' }).fill('1');
    await page.getByRole('spinbutton', { name: 'Exponent *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Bonus Pool Percentage *' }).fill('3.0');
    await page.getByRole('spinbutton', { name: 'Min List Weight *' }).fill('1');
    await page.getByRole('button', { name: 'Create Configuration' }).click();
    await page.waitForURL(/\/admin\/ranking_configurations\/\d+/);

    // Open Actions dropdown
    await page.getByText('Actions', { exact: true }).click();

    // Verify action buttons
    await expect(page.getByRole('button', { name: 'Recalculate List Weights' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Refresh Rankings' })).toBeVisible();

    // Cleanup
    await deleteRankingConfiguration(page);
  });
});
