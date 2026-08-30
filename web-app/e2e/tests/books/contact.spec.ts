import { test, expect } from '@playwright/test';

// The contact form is one FooterComponent shared by books, music and games, and
// is covered per-domain by test/components/footer_component_test.rb. These run
// against books alone because it is the one e2e project here that needs no auth
// setup.
test.describe('Contact form', () => {
  test('opens from the footer', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: 'Contact us' })).toBeVisible();
  });

  test('sends an anonymous message and confirms in place', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await dialog.getByLabel('Your email').fill('e2e-reader@example.org');
    await dialog.getByLabel('Message').fill('An end-to-end test message.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    // The modal stays open and swaps its body -- public layouts render no flash,
    // so this panel is the only confirmation there is.
    await expect(dialog.getByText(/your message is on its way/i)).toBeVisible();
  });

  test('rejects a message with no address', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await dialog.getByLabel('Message').fill('No address on this one.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    // The browser's own required-field validation stops this before the request.
    await expect(dialog.getByLabel('Your email')).toBeFocused();
  });

  // Regression: close() only closed the dialog and open() only opened it --
  // nothing ever put the form back after a successful send replaced it with
  // the thanks panel. A visitor who sent one message and later wanted to send
  // another got "Thanks" again with no form and no way to submit, for the
  // life of the page.
  test('reopening after a successful send shows a fresh, submittable form', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await dialog.getByLabel('Your email').fill('e2e-reopen@example.org');
    await dialog.getByLabel('Message').fill('First message before reopening.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    await expect(dialog.getByText(/your message is on its way/i)).toBeVisible();

    // exact: true -- the dialog's own backdrop-close button is also named
    // "close" (lowercase, from `<form method="dialog">`), and getByRole's
    // default name match is case-insensitive.
    await dialog.getByRole('button', { name: 'Close', exact: true }).click();
    await expect(dialog).not.toBeVisible();

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: 'Contact us' })).toBeVisible();

    const emailField = dialog.getByLabel('Your email');
    const messageField = dialog.getByLabel('Message');
    await expect(emailField).toBeVisible();
    await expect(messageField).toBeVisible();
    await expect(emailField).toHaveValue('');
    await expect(messageField).toHaveValue('');

    // Not just present -- actually submittable a second time.
    await emailField.fill('e2e-reopen-2@example.org');
    await messageField.fill('Second message after reopening.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    await expect(dialog.getByText(/your message is on its way/i)).toBeVisible();
  });

  test('closes without sending', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await expect(dialog).toBeVisible();

    await dialog.getByRole('button', { name: 'Cancel' }).click();

    await expect(dialog).not.toBeVisible();
  });
});
