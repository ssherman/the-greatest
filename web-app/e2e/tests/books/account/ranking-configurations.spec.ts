import { test, expect, type Page } from '@playwright/test';

// Owner flow for user-owned ranking configurations (spec
// docs/superpowers/specs/2026-09-12-user-ranking-configurations-design.md).
//
// Budget: the shared E2E account may own 5 rankings and trigger 5 manual
// refreshes a day. This spec creates one from scratch (so the automatic
// first calculation is instant), spends ONE manual refresh, and deletes the
// ranking at the end; the first test also sweeps any leftovers from a
// failed run so the cap can never wedge the account. Do not run it more
// than five times a day.

const BASE_URL = 'https://dev-new.thegreatestbooks.org';
const PREFIX = 'E2E ranking';
const runId = Date.now();
const name = `${PREFIX} ${runId}`;

let configId: string;

async function sweepLeftovers(page: Page): Promise<void> {
  for (let attempt = 0; attempt < 6; attempt += 1) {
    await page.goto('/my/rankings');
    const leftover = page.getByRole('article').filter({ hasText: PREFIX }).first();
    if ((await leftover.count()) === 0) return;
    await leftover.getByRole('link', { name: 'Manage' }).click();
    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL(/\/my\/rankings$/);
  }
}

test.describe.serial('user-owned ranking configurations', () => {
  test('create from scratch, tune, manage lists, refresh, share', async ({ page }) => {
    await sweepLeftovers(page);

    await page.goto('/my/rankings');
    await page.getByRole('link', { name: 'New ranking' }).click();
    await page.getByRole('link', { name: 'Or start from scratch' }).click();
    await expect(page).toHaveURL(/start=scratch/);

    await page.getByLabel('Name', { exact: true }).fill(name);
    await page.getByLabel('Description').fill('Built by the E2E suite.');
    await page.getByLabel('Share via link').check();
    await page.getByRole('button', { name: 'Create ranking' }).click();

    await expect(page).toHaveURL(/\/my\/rankings\/\d+$/);
    configId = page.url().match(/\/my\/rankings\/(\d+)$/)![1];
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(name);
    await expect(page.getByLabel('Share link')).toHaveValue(`${BASE_URL}/rc/${configId}`);

    // A from-scratch ranking has nothing to calculate; the automatic first
    // run finishes almost immediately.
    await expect(page.getByText('Up to date', { exact: true })).toBeVisible({ timeout: 60_000 });

    // Manage lists: add one by search, add one from the diff, remove one.
    await page.getByRole('link', { name: 'Manage lists' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(0\)/ })).toBeVisible();

    const search = page.getByLabel('Search lists');
    await search.fill('Guardian');
    const firstResult = page.locator('[data-saved-search-picker-target="results"] button').first();
    await expect(firstResult).toBeVisible();
    const pickedName = (await firstResult.innerText()).replace(/\s+\(.*\)$/, '');
    await firstResult.click();
    await page.getByRole('button', { name: 'Add selected lists' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(1\)/ })).toBeVisible();
    await expect(page.locator('turbo-frame#rc_lists').getByRole('link', { name: pickedName })).toBeVisible();

    const firstMissingAdd = page.locator('turbo-frame#rc_lists tr[id^="missing-list-"]').first().getByRole('button', { name: 'Add' });
    await firstMissingAdd.click();
    await expect(page.getByRole('heading', { name: /^Your lists \(2\)/ })).toBeVisible();

    page.once('dialog', (dialog) => dialog.accept());
    await page.locator('turbo-frame#rc_lists tr[id^="ranked-list-"]').first().getByRole('button', { name: 'Remove' }).click();
    await expect(page.getByRole('heading', { name: /^Your lists \(1\)/ })).toBeVisible();
    await expect(page.getByText('Needs refresh', { exact: true })).toBeVisible();

    // Refresh (one of five for the day) and wait for the poller to reload.
    await page.getByRole('button', { name: 'Refresh weights and rankings' }).click();
    await expect(page).toHaveURL(`/my/rankings/${configId}`);
    await expect(page.getByText('Up to date', { exact: true })).toBeVisible({ timeout: 120_000 });

    // Public view with the banner.
    await page.goto(`/rc/${configId}`);
    await expect(page.getByRole('status').filter({ hasText: "You're viewing a custom ranking" })).toBeVisible();
    await expect(page.getByRole('status').filter({ hasText: name })).toBeVisible();
  });

  test('a shared ranking is public, a private one is not', async ({ browser, page }) => {
    // browser.newContext() inherits the project's storageState (the signed-in
    // E2E user) by default; without overriding it here this "anonymous"
    // context would actually be signed in as the owner, and the 404 check
    // below would pass for the wrong reason.
    const anonymous = await browser.newContext({ storageState: undefined });
    const anonymousPage = await anonymous.newPage();

    const shared = await anonymousPage.goto(`/rc/${configId}`);
    expect(shared?.status()).toBe(200);
    await expect(anonymousPage.getByRole('status').filter({ hasText: name })).toBeVisible();

    await page.goto(`/my/rankings/${configId}/edit`);
    await page.getByLabel('Share via link').uncheck();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page).toHaveURL(`/my/rankings/${configId}`);

    const hidden = await anonymousPage.goto(`/rc/${configId}`);
    expect(hidden?.status()).toBe(404);
    await anonymous.close();
  });

  test('delete', async ({ page }) => {
    await page.goto(`/my/rankings/${configId}`);
    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL(/\/my\/rankings$/);
    await expect(page.getByRole('article').filter({ hasText: name })).toHaveCount(0);
  });
});
