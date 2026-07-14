import { type Page } from '@playwright/test';
import { test, expect } from '../../../fixtures/auth';
import { AlbumListsPage } from '../../../pages/music/admin/album-lists-page';

// Finds the first list on the Album Lists index that already has items, then
// navigates into its show page. The dev database is rebuilt periodically and
// ids are not stable, so we discover a usable list at runtime instead of
// hardcoding one.
async function openFirstListWithItems(page: Page, albumListsPage: AlbumListsPage) {
  await albumListsPage.goto();
  await expect(albumListsPage.table).toBeVisible();

  const rows = albumListsPage.tableRows;
  const rowCount = await rows.count();
  let found = false;

  for (let i = 0; i < rowCount; i++) {
    const row = rows.nth(i);
    const itemCount = Number((await row.locator('td').nth(5).innerText()).trim());

    if (itemCount > 0) {
      await row.locator('td').nth(2).locator('a').first().click();
      found = true;
      break;
    }
  }

  if (!found) {
    throw new Error('No album list with items found on the first page of the Album Lists index');
  }

  // The list-items card renders a lazy-loaded turbo frame (loading: :lazy), so it only
  // fetches once it scrolls into the viewport. Scroll it into view and wait for the
  // loading spinner to be replaced by the real content before interacting with it.
  const itemsFrame = page.locator('turbo-frame#list_items_list');
  await itemsFrame.scrollIntoViewIfNeeded();
  await expect(itemsFrame.locator('.loading-spinner')).toBeHidden({ timeout: 10000 });
}

test.describe('Admin List Items - Single Instance Modal', () => {
  test('renders exactly one edit-list-item dialog on the page', async ({ page, albumListsPage }) => {
    await openFirstListWithItems(page, albumListsPage);

    const itemsFrame = page.locator('turbo-frame#list_items_list');
    await expect(itemsFrame.locator('table')).toBeVisible();

    await expect(page.locator('dialog#edit_list_item_modal_dialog')).toHaveCount(1);
  });

  test('loads the edit form on demand and saves a position change', async ({ page, albumListsPage }) => {
    await openFirstListWithItems(page, albumListsPage);

    const table = page.locator('turbo-frame#list_items_list table');
    await expect(table).toBeVisible();

    // Add a disposable, unverified item to edit rather than mutating one of the
    // list's real (curated) rows. Leaving the autocomplete field untouched keeps
    // it unresolved, which is fine here since we only care about its position.
    await page.getByRole('button', { name: '+ Add Album' }).click();
    const addDialog = page.locator('dialog#add_item_to_list_modal_dialog');
    await expect(addDialog).toBeVisible();
    await addDialog.getByRole('spinbutton').fill('1');
    await addDialog.getByRole('button', { name: 'Add Album', exact: true }).click();
    await expect(addDialog).toBeHidden();

    // The new row is unverified (no listable) and sorts to the top with position 1,
    // so it's the first "Unverified Item" row in position order.
    const unverifiedRows = table.locator('tbody tr', { hasText: 'Unverified Item' });
    const newRow = unverifiedRows.first();
    await expect(newRow.locator('td').first()).toHaveText('1');

    // The edit form is not pre-rendered - only the dialog shell and its (empty) frame exist.
    await expect(page.locator('#edit_list_item_modal_content form')).toHaveCount(0);

    await newRow.locator('td').last().getByRole('link').click();

    const dialog = page.locator('dialog#edit_list_item_modal_dialog');
    await expect(dialog).toBeVisible();

    const form = page.locator('#edit_list_item_modal_content form');
    await expect(form).toBeVisible();

    await form.getByRole('spinbutton').fill('2');
    await form.getByRole('button', { name: 'Update Item' }).click();

    await expect(dialog).toBeHidden();

    const updatedRow = unverifiedRows.first();
    await expect(updatedRow.locator('td').first()).toHaveText('2');

    // Clean up the disposable item so the list is left as it was found.
    page.once('dialog', (confirmDialog) => confirmDialog.accept());
    await updatedRow.locator('td').last().getByRole('button').click();
    await expect(unverifiedRows.first().locator('td').first()).not.toHaveText('2');
  });
});
