import { test, expect } from '@playwright/test';

// Task 4 added the per-site contact admin queue with no seed data of its own,
// and the controller has no destroy action -- only resolve. So this drives the
// real pipeline the way admin/corrections.spec.ts does: submit through the
// public footer form rather than seeding a ContactMessage row directly. The
// books-admin project's storage state carries the signed-in Playwright admin
// session onto the public "/" page too, so the submission lands as that user
// (the server reads current_user.email and ignores whatever the field holds).
//
// Marking the message replied at the end is both an assertion and the
// cleanup: there being no delete route, moving the row out of the pending
// tab is the only "clean up after yourself" available here, and it is also
// exactly the behaviour this spec exists to cover.
const MARKER = `E2E admin contact-messages spec ${Date.now()}`;

test.describe('Books admin — contact messages', () => {
  test('a submitted message appears in the pending queue, shows its body, and can be marked replied', async ({ page }) => {
    await page.goto('/');
    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await expect(dialog).toBeVisible();

    // Signed in: contact--form fetches /contact_state when the dialog opens and
    // fills+locks the email field with the admin's own address. Wait for that
    // round trip rather than racing it -- an empty required field would block
    // the browser's own validation before the request is ever sent.
    await expect(dialog.getByLabel('Your email')).not.toHaveValue('');
    await dialog.getByLabel('Message').fill(MARKER);
    await dialog.getByRole('button', { name: 'Send' }).click();
    await expect(dialog.getByText(/your message is on its way/i)).toBeVisible();

    // No need to close the dialog -- the navigation below unloads the page.
    // (Its native backdrop-close button is also named "close", lowercase, so
    // a role query for "Close" here would be ambiguous.)
    await page.goto('/admin/contact_messages');
    await expect(page.getByTestId('status-tab-pending')).toHaveClass(/tab-active/);

    // Found by the marker text, never by position -- other specs and real
    // traffic can add pending rows of their own.
    const row = page.locator('[data-testid="contact-message-row"]', { hasText: MARKER });
    await expect(row).toBeVisible();
    const messageId = await row.getAttribute('data-contact-message-id');
    expect(messageId, 'expected the row to carry a data-contact-message-id').toBeTruthy();

    await row.getByRole('link').click();
    await expect(page).toHaveURL(new RegExp(`/admin/contact_messages/${messageId}$`));

    // Proves the show page renders the FULL body, not just the row's
    // 80-character truncation -- non-vacuous because MARKER already fits
    // under that truncation, so this also confirms it round-tripped intact.
    await expect(page.getByText(MARKER)).toBeVisible();

    await page.getByRole('button', { name: 'Mark replied' }).click();

    // resolve redirects to the index with no status param, i.e. the pending
    // tab, and this message must no longer be in it.
    await expect(page).toHaveURL(/\/admin\/contact_messages$/);
    await expect(page.getByText('Message marked replied.')).toBeVisible();
    await expect(page.getByTestId('status-tab-pending')).toHaveClass(/tab-active/);
    await expect(page.locator(`[data-contact-message-id="${messageId}"]`)).toHaveCount(0);

    // It reappears under Replied -- proof the resolve action actually wrote
    // the status change to the database and the index's status filter reads
    // it back, not just that the controller returned a friendly string.
    await page.getByTestId('status-tab-replied').click();
    const repliedRow = page.locator(`[data-contact-message-id="${messageId}"]`);
    await expect(repliedRow).toBeVisible();
    await expect(repliedRow).toHaveAttribute('data-status', 'replied');
  });
});
