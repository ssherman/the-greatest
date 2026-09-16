import { test, expect, type Page } from '@playwright/test';

// Matched by `books-member`: PLAYWRIGHT_MEMBER_EMAIL, comped by
// `bin/rails e2e:member`. Creates a real token on the shared dev database, so
// it cleans up after itself and also before it starts, in case an earlier run
// died between create and revoke (the account holds at most 10 tokens).
const TOKEN_NAME = 'E2E token';
const SECRET = /^tg_[A-Za-z0-9]{40}$/;

// Assumes the page's dialog handler is already installed (beforeEach below):
// a second `page.on('dialog')` that also calls accept() throws on an
// already-handled dialog.
async function revokeLeftovers(page: Page) {
  await page.goto('/developers/tokens');
  const revokes = page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true });
  let remaining = await revokes.count();
  while (remaining > 0) {
    await revokes.first().click();
    // Wait on the whole set, not on .first(): with two leftovers, .first()
    // simply resolves to the next one and never reaches count 0.
    await expect(revokes).toHaveCount(remaining - 1);
    remaining -= 1;
  }
}

test.describe('Books API tokens, as a member', () => {
  test.beforeEach(async ({ page }) => {
    // One handler per page (Playwright gives each test its own page): every
    // revoke button carries a turbo_confirm, which is a native confirm().
    page.on('dialog', (dialog) => dialog.accept());
    await revokeLeftovers(page);
  });

  test.afterEach(async ({ page }) => {
    await revokeLeftovers(page);
  });

  test('the members area shows the API card', async ({ page }) => {
    await page.goto('/members');

    await page.getByRole('link', { name: 'Manage tokens' }).click();

    await expect(page).toHaveURL(/\/developers\/tokens$/);
    await expect(page.getByRole('heading', { level: 1, name: /API tokens/ })).toBeVisible();
  });

  test('create, see the secret once, use it, revoke it, and it stops working', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    await page.getByLabel('Expires').selectOption('30');
    await page.getByRole('button', { name: 'Create token' }).click();

    // The secret arrives in a Turbo Stream, in one readonly input, once.
    const secretInput = page.getByTestId('token-secret');
    await expect(secretInput).toBeVisible();
    const secret = await secretInput.inputValue();
    expect(secret).toMatch(SECRET);
    await expect(page.getByTestId('new-token').getByRole('alert')).toContainText(/only time/i);

    // The list gained a row showing the display prefix, not the secret.
    const row = page.getByRole('row', { name: new RegExp(TOKEN_NAME) });
    await expect(row).toContainText(secret.slice(0, 12));
    await expect(row).not.toContainText(secret);

    // The token works against the API, with the account-tier rate headers.
    const ok = await page.request.get('/api/v1/books?per_page=1', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(ok.status()).toBe(200);
    expect(ok.headers()['x-ratelimit-limit']).toBe('60');
    expect(ok.headers()['x-ratelimit-daily-limit']).toBe('5000');
    const body = await ok.json();
    expect(body.data).toHaveLength(1);
    expect(body.data[0]).toHaveProperty('rank');

    // Shown once: a reload has no secret on it.
    await page.reload();
    await expect(page.getByTestId('token-secret')).toHaveCount(0);
    expect(await page.content()).not.toContain(secret);

    // Revoke (the beforeEach dialog handler accepts the confirm), then the
    // same call is a 401.
    await page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true }).click();
    await expect(page.getByRole('row', { name: new RegExp(TOKEN_NAME) })).toHaveCount(0);

    const gone = await page.request.get('/api/v1/books?per_page=1', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(gone.status()).toBe(401);
    expect(gone.headers()['www-authenticate']).toContain('error="invalid_token"');
  });

  test('a submission with no scopes is refused in place and keeps the name', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    for (const scope of ['books:read', 'music:read', 'games:read']) {
      await page.getByLabel(new RegExp(`^${scope}`)).uncheck();
    }
    await page.getByRole('button', { name: 'Create token' }).click();

    await expect(page.getByTestId('token-form-error')).toBeVisible();
    await expect(page.getByLabel('Name')).toHaveValue(TOKEN_NAME);
    await expect(page.getByTestId('token-secret')).toHaveCount(0);
    await expect(page).toHaveURL(/\/developers\/tokens$/);
  });
});
