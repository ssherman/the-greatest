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
const RUN_ID = Date.now();

// The row partial truncates the message to 80 characters
// (app/views/admin/contact_messages/_row.html.erb), so a marker that fits
// entirely inside that window would let the show page's "renders the FULL
// body" claim below pass even if the show page regressed to truncating at
// 80 too -- exactly the bug this test exists to catch. PREFIX is padded
// past 80 characters on purpose so TAIL exists only beyond the truncation
// boundary: the index row can only ever show PREFIX (or less), and the show
// page assertion goes red the moment it stops rendering past character 80.
// If you ever touch this marker, keep TAIL past character 80 or this
// guarantee silently breaks again.
const PREFIX = `E2E admin contact-messages spec ${RUN_ID} `.padEnd(90, '.');
const TAIL = `TAIL-${RUN_ID}`;
const MARKER = `${PREFIX}${TAIL}`;

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

    // Found by RUN_ID, never by position -- other specs and real traffic can
    // add pending rows of their own. RUN_ID sits well inside PREFIX, so it
    // survives the row's 80-character truncation even though the full
    // MARKER (with TAIL) does not.
    const row = page.locator('[data-testid="contact-message-row"]', { hasText: String(RUN_ID) });
    await expect(row).toBeVisible();
    const messageId = await row.getAttribute('data-contact-message-id');
    expect(messageId, 'expected the row to carry a data-contact-message-id').toBeTruthy();

    await row.getByRole('link').click();
    await expect(page).toHaveURL(new RegExp(`/admin/contact_messages/${messageId}$`));

    // Proves the show page renders the FULL body, not just the row's
    // 80-character truncation: TAIL exists only past character 80 of the
    // message, so this fails if the show page ever truncates the same way
    // the row does. Asserting on TAIL alone, not the whole MARKER, is what
    // makes that failure mode reachable.
    await expect(page.getByText(TAIL)).toBeVisible();

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
