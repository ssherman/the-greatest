import { test, expect, type Page } from '@playwright/test';

// Admin API tokens: an admin sees the books admin scopes on /developers/tokens
// and can mint one, which must expire. Creates a real token on the shared dev
// database, so it revokes leftovers before and after.
const TOKEN_NAME = 'E2E admin token';
const SECRET = /^tg_[A-Za-z0-9]{40}$/;

async function revokeLeftovers(page: Page) {
  await page.goto('/developers/tokens');
  const revokes = page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true });
  let remaining = await revokes.count();
  while (remaining > 0) {
    await revokes.first().click();
    await expect(revokes).toHaveCount(remaining - 1);
    remaining -= 1;
  }
}

test.describe('Books API tokens, as an admin', () => {
  test.beforeEach(async ({ page }) => {
    page.on('dialog', (dialog) => dialog.accept());
    await revokeLeftovers(page);
  });

  test.afterEach(async ({ page }) => {
    await revokeLeftovers(page);
  });

  test('the admin scopes are offered', async ({ page }) => {
    await page.goto('/developers/tokens');

    await expect(page.getByLabel(/^\s*books:admin:read/)).toBeVisible();
    await expect(page.getByLabel(/^\s*books:admin:merge/)).toBeVisible();
  });

  test('an admin scope without an expiry is refused', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    await page.getByLabel(/^\s*books:admin:merge/).check();
    await page.getByRole('button', { name: 'Create token' }).click();

    await expect(page.getByTestId('token-form-error')).toContainText(/expires at must be set/i);
    await expect(page.getByTestId('token-secret')).toHaveCount(0);
  });

  test('create an admin token with an expiry, then revoke it', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    await page.getByLabel(/^\s*books:admin:merge/).check();
    await page.getByLabel('Expires').selectOption('30');
    await page.getByRole('button', { name: 'Create token' }).click();

    const secretInput = page.getByTestId('token-secret');
    await expect(secretInput).toBeVisible();
    expect(await secretInput.inputValue()).toMatch(SECRET);

    await page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true }).click();
    await expect(page.getByRole('row', { name: new RegExp(TOKEN_NAME) })).toHaveCount(0);
  });
});
