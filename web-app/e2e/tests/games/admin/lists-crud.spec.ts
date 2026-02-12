import { test, expect } from '../../../fixtures/games-auth';

test.describe('Games Admin Lists', () => {
  test('index page loads with heading and subtitle', async ({ listsPage }) => {
    await listsPage.goto();

    await expect(listsPage.heading).toBeVisible();
    await expect(listsPage.subtitle).toBeVisible();
  });

  test('index page shows search input and status filter', async ({ listsPage }) => {
    await listsPage.goto();

    await expect(listsPage.searchInput).toBeVisible();
    await expect(listsPage.statusFilter).toBeVisible();
  });

  test('index page shows New List button', async ({ listsPage }) => {
    await listsPage.goto();

    await expect(listsPage.newListButton.first()).toBeVisible();
  });

  test('create a new list', async ({ listsPage, page }) => {
    const uniqueName = `E2E Test List ${Date.now()}`;
    await listsPage.goto();
    await listsPage.newListButton.first().click();

    await expect(page).toHaveURL(/\/admin\/lists\/new/);

    await page.getByRole('textbox', { name: 'Name *' }).fill(uniqueName);
    await page.getByLabel(/Source/).first().fill('E2E Test Source');
    await page.getByRole('button', { name: 'Create Game List' }).click();

    await page.waitForURL(/\/admin\/lists\/\d+/);
    await expect(page.getByRole('heading', { name: uniqueName })).toBeVisible();
  });

  test('read - navigate to show page and verify content', async ({ listsPage, page }) => {
    // First create a list to view
    const name = `E2E Read List ${Date.now()}`;
    await listsPage.goto();
    await listsPage.newListButton.first().click();
    await page.getByRole('textbox', { name: 'Name *' }).fill(name);
    await page.getByLabel(/Source/).first().fill('Read Test Source');
    await page.getByRole('button', { name: 'Create Game List' }).click();
    await page.waitForURL(/\/admin\/lists\/\d+/);

    // Verify show page content
    await expect(page.getByRole('heading', { name: name })).toBeVisible();
    await expect(page.getByText('Basic Information')).toBeVisible();
    await expect(page.getByRole('heading', { name: /Games/ }).first()).toBeVisible();
    await expect(page.getByRole('heading', { name: /Penalties/ })).toBeVisible();
  });

  test('update an existing list', async ({ listsPage, page }) => {
    // First create a list to edit
    const originalName = `E2E Edit List ${Date.now()}`;
    await listsPage.goto();
    await listsPage.newListButton.first().click();
    await page.getByRole('textbox', { name: 'Name *' }).fill(originalName);
    await page.getByRole('button', { name: 'Create Game List' }).click();
    await page.waitForURL(/\/admin\/lists\/\d+/);

    // Now edit it
    await page.getByRole('link', { name: 'Edit' }).click();
    await expect(page).toHaveURL(/\/edit/);

    const updatedName = `E2E Updated List ${Date.now()}`;
    await page.getByRole('textbox', { name: 'Name *' }).fill(updatedName);
    await page.getByRole('button', { name: 'Update Game List' }).click();

    await page.waitForURL(/\/admin\/lists\/\d+/);
    await expect(page.getByRole('heading', { name: updatedName })).toBeVisible();
  });

  test('delete a list', async ({ listsPage, page }) => {
    // First create a list to delete
    const listName = `E2E Delete List ${Date.now()}`;
    await listsPage.goto();
    await listsPage.newListButton.first().click();
    await page.getByRole('textbox', { name: 'Name *' }).fill(listName);
    await page.getByRole('button', { name: 'Create Game List' }).click();
    await page.waitForURL(/\/admin\/lists\/\d+/);

    // Handle the turbo_confirm dialog
    page.on('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();

    await expect(page).toHaveURL(/\/admin\/lists$/);
  });

  test('search filters the table', async ({ listsPage, page }) => {
    // Create a list with a unique name for searching
    const searchName = `E2E Search ${Date.now()}`;
    await listsPage.goto();
    await listsPage.newListButton.first().click();
    await page.getByRole('textbox', { name: 'Name *' }).fill(searchName);
    await page.getByRole('button', { name: 'Create Game List' }).click();
    await page.waitForURL(/\/admin\/lists\/\d+/);

    // Go back to index and search
    await listsPage.goto();
    await listsPage.searchInput.fill(searchName);
    await page.waitForTimeout(500); // Wait for debounce
    await page.keyboard.press('Enter');

    await expect(page.getByRole('link', { name: searchName })).toBeVisible();
  });

  test('status filter updates the table', async ({ listsPage, page }) => {
    await listsPage.goto();

    await listsPage.statusFilter.selectOption('approved');
    await page.waitForTimeout(500); // Wait for form submission

    await expect(page).toHaveURL(/status=approved/);
  });
});

test.describe('Games Admin List Penalties', () => {
  /**
   * Helper: creates a fresh list and navigates to its show page.
   * Scrolls to the penalties section and waits for the lazy turbo frame to load.
   */
  async function createListAndWaitForPenalties(listsPage: any, page: any, listName: string) {
    await listsPage.goto();
    await listsPage.newListButton.first().click();
    await page.getByRole('textbox', { name: 'Name *' }).fill(listName);
    await page.getByRole('button', { name: 'Create Game List' }).click();
    await page.waitForURL(/\/admin\/lists\/\d+/);

    // Scroll to penalties section to trigger lazy turbo frame loading
    const attachButton = page.getByRole('button', { name: '+ Attach Penalty' });
    await attachButton.scrollIntoViewIfNeeded();

    // Wait for the lazy-loaded turbo frame to finish loading
    const penaltiesFrame = page.locator('turbo-frame#list_penalties_list');
    await expect(penaltiesFrame.locator('.loading-spinner')).toBeHidden({ timeout: 10000 });

    return penaltiesFrame;
  }

  test('show page displays empty penalties section', async ({ listsPage, page }) => {
    const name = `E2E Penalty List ${Date.now()}`;
    const penaltiesFrame = await createListAndWaitForPenalties(listsPage, page, name);

    await expect(penaltiesFrame.getByText('No penalties attached to this list yet.')).toBeVisible({ timeout: 10000 });
  });

  test('attach a penalty via modal', async ({ listsPage, page }) => {
    const name = `E2E Attach Penalty ${Date.now()}`;
    const penaltiesFrame = await createListAndWaitForPenalties(listsPage, page, name);

    // Open the attach penalty modal
    await page.getByRole('button', { name: '+ Attach Penalty' }).click();
    const modal = page.locator('#attach_penalty_modal_dialog');
    await expect(modal).toBeVisible();

    // Select the first available penalty from the dropdown
    const penaltySelect = modal.locator('select[name="list_penalty[penalty_id]"]');
    await expect(penaltySelect).toBeVisible();
    const options = penaltySelect.locator('option:not([value=""])');
    const firstOptionValue = await options.first().getAttribute('value');
    const firstOptionText = await options.first().innerText();
    await penaltySelect.selectOption(firstOptionValue!);

    // Submit the form
    await modal.getByRole('button', { name: 'Attach Penalty' }).click();

    // Verify penalty appears in the list (turbo stream updates the frame)
    await expect(penaltiesFrame.getByText(firstOptionText)).toBeVisible({ timeout: 10000 });
  });

  test('detach a penalty', async ({ listsPage, page }) => {
    const name = `E2E Detach Penalty ${Date.now()}`;
    const penaltiesFrame = await createListAndWaitForPenalties(listsPage, page, name);

    // Attach a penalty first
    await page.getByRole('button', { name: '+ Attach Penalty' }).click();
    const modal = page.locator('#attach_penalty_modal_dialog');
    await expect(modal).toBeVisible();

    const penaltySelect = modal.locator('select[name="list_penalty[penalty_id]"]');
    const options = penaltySelect.locator('option:not([value=""])');
    const firstOptionText = await options.first().innerText();
    await penaltySelect.selectOption({ index: 1 });
    await modal.getByRole('button', { name: 'Attach Penalty' }).click();

    // Verify penalty is attached
    await expect(penaltiesFrame.getByText(firstOptionText)).toBeVisible({ timeout: 10000 });

    // Detach the penalty
    page.on('dialog', dialog => dialog.accept());
    await penaltiesFrame.getByRole('button', { name: 'Delete' }).click();

    // Verify penalty is removed
    await expect(penaltiesFrame.getByText('No penalties attached to this list yet.')).toBeVisible({ timeout: 10000 });
  });

  test('attach multiple penalties', async ({ listsPage, page }) => {
    const name = `E2E Multi Penalty ${Date.now()}`;
    const penaltiesFrame = await createListAndWaitForPenalties(listsPage, page, name);

    // Attach first penalty
    await page.getByRole('button', { name: '+ Attach Penalty' }).click();
    let modal = page.locator('#attach_penalty_modal_dialog');
    await expect(modal).toBeVisible();
    let penaltySelect = modal.locator('select[name="list_penalty[penalty_id]"]');
    const firstPenaltyText = await penaltySelect.locator('option:not([value=""])').first().innerText();
    await penaltySelect.selectOption({ index: 1 });
    await modal.getByRole('button', { name: 'Attach Penalty' }).click();
    await expect(penaltiesFrame.getByText(firstPenaltyText)).toBeVisible({ timeout: 10000 });

    // Attach second penalty
    await page.getByRole('button', { name: '+ Attach Penalty' }).click();
    modal = page.locator('#attach_penalty_modal_dialog');
    await expect(modal).toBeVisible();
    penaltySelect = modal.locator('select[name="list_penalty[penalty_id]"]');
    const secondPenaltyText = await penaltySelect.locator('option:not([value=""])').first().innerText();
    await penaltySelect.selectOption({ index: 1 });
    await modal.getByRole('button', { name: 'Attach Penalty' }).click();
    await expect(penaltiesFrame.getByText(secondPenaltyText)).toBeVisible({ timeout: 10000 });

    // Verify both penalties are visible
    await expect(penaltiesFrame.getByText(firstPenaltyText)).toBeVisible();
    await expect(penaltiesFrame.getByText(secondPenaltyText)).toBeVisible();
  });
});
