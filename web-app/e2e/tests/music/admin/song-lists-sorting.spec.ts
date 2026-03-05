import { test, expect } from '../../../fixtures/auth';

test.describe('Admin Song Lists - Updated At Sorting', () => {
  test('clicking Updated column header sorts by updated_at', async ({ songListsPage, page }) => {
    await songListsPage.goto();

    await expect(songListsPage.table).toBeVisible();

    // Click the "Updated" column header to sort ascending
    const updatedLink = page.getByRole('link', { name: 'Updated', exact: true });
    await updatedLink.click();

    // After Turbo frame update, the sort link should now toggle to desc
    await expect(updatedLink).toHaveAttribute('href', /sort=updated_at/);
    await expect(updatedLink).toHaveAttribute('href', /direction=desc/);
    await expect(songListsPage.table).toBeVisible();

    // Click again to sort descending
    await updatedLink.click();

    // After second click, should toggle back to asc
    await expect(updatedLink).toHaveAttribute('href', /sort=updated_at/);
    await expect(updatedLink).toHaveAttribute('href', /direction=asc/);
    await expect(songListsPage.table).toBeVisible();
  });
});
