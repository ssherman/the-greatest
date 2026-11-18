import { test, expect } from '@playwright/test';

test.describe('Books add-to-list widget', () => {
  test('the widget button on a ranked-grid card is clickable and opens the modal', async ({ page }) => {
    await page.goto('/');

    const card = page.locator('[data-listable-type="Books::Book"]').first();
    await card.getByRole('button', { name: /Add to list/i }).click();

    await expect(page.locator('#user_list_modal')).toBeVisible();
  });

  test('ticking a list adds the book and the state survives a reload', async ({ page }) => {
    await page.goto('/');

    const card = page.locator('[data-listable-type="Books::Book"]').first();
    const listableId = await card.getAttribute('data-listable-id');
    await card.getByRole('button', { name: /Add to list/i }).click();

    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const row = modal.getByRole('checkbox').first();
    // Reloading before the POST lands loses the add and fails the check below.
    const added = page.waitForResponse((r) => r.request().method() === 'POST' && r.url().includes('/items'));
    await row.check();
    await expect(row).toBeChecked();
    await added;
    await page.keyboard.press('Escape');

    await page.reload();
    const sameCard = page.locator(`[data-listable-id="${listableId}"]`).first();
    await expect(sameCard.locator('[data-user-list-widget-target="iconStrip"]')).not.toHaveClass(/hidden/);

    // Leave the account as we found it. The widget's button label switches to
    // "On N lists" once the item has a membership, so it can no longer be
    // targeted by the "Add to list" name here — there is only one button on
    // the card, so an unqualified role lookup is unambiguous.
    await sameCard.getByRole('button').click();
    const removed = page.waitForResponse((r) => r.request().method() === 'DELETE' && r.url().includes('/items'));
    await modal.getByRole('checkbox').first().uncheck();
    await removed;
  });

  test('the widget on the book show page opens the modal', async ({ page }) => {
    await page.goto('/');
    await page.locator('[data-listable-type="Books::Book"] a').first().click();

    await page.getByRole('button', { name: /Add to list/i }).first().click();
    await expect(page.locator('#user_list_modal')).toBeVisible();
  });
});
