import { test, expect, type Page } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';
import { expectSignedIn, expectSignedOut } from '../../../support/sign-in-state';
import { ageCache, cachedEntry, countStateRequests } from '../../../support/state-requests';

// A signed-in page load makes at most one Rails state request, and usually none:
// the per-user state is cached in localStorage and re-checked hourly. Each test
// signs in for real because Firebase's IndexedDB is not part of storage state.
test.use({ storageState: { cookies: [], origins: [] } });

const HOUR = 60 * 60 * 1000;
const ORDINARY_PAGES = ['/rankings', '/lists', '/membership'];

// Fills the cache entry: the first ordinary page after sign-in is the one that
// has to ask. Waiting on the entry (not a sleep) is what makes later counts exact.
async function signInAndFillCache(page: Page, account: 'USER' | 'MEMBER') {
  await signIn(page, credentials(account));
  await page.goto('/');
  await expectSignedIn(page);
  await expect.poll(() => cachedEntry(page), { timeout: 15_000 }).not.toBeNull();
}

async function openFirstBookPage(page: Page) {
  await page.goto('/');
  const href = await page.locator('[data-listable-type="Books::Book"] a').first().getAttribute('href');
  expect(href).toBeTruthy();
  return href!;
}

test.describe('Per-user state requests (books)', () => {
  test('ordinary pages make no state requests within the hour', async ({ page }) => {
    await signInAndFillCache(page, 'USER');

    const requests = countStateRequests(page);
    for (const path of ORDINARY_PAGES) {
      await page.goto(path);
      await expectSignedIn(page);
    }
    expect(requests.get()).toBe(0);
  });

  test('an aged cache makes exactly one conditional request, answered with a 304', async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    await ageCache(page, HOUR + 60_000);

    const requests = countStateRequests(page);
    const response = page.waitForResponse((res) => new URL(res.url()).pathname === '/user_list_state');
    await page.goto('/rankings');
    await expectSignedIn(page);
    const stateResponse = await response;

    expect(requests.get()).toBe(1);
    expect(requests.requests('/user_list_state')[0].headers()['if-none-match']).toBeTruthy();
    // Nothing changed, so the server must say so rather than resend the body.
    expect(stateResponse.status()).toBe(304);

    // The re-check restamps the entry, so the next page is free again.
    await page.goto('/lists');
    await expectSignedIn(page);
    expect(requests.get()).toBe(1);
  });

  test('the Members link shows without a /membership_state request', async ({ page }) => {
    await signInAndFillCache(page, 'MEMBER');

    const requests = countStateRequests(page);
    await page.goto('/rankings');
    await expect(page.locator('#navbar_members:visible')).not.toHaveCount(0);
    expect(requests.get('/membership_state')).toBe(0);
    expect(requests.get()).toBe(0);
  });

  test('a book page makes exactly one state request even when the re-check is due', async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    const href = await openFirstBookPage(page);
    await ageCache(page, HOUR + 60_000);

    const requests = countStateRequests(page);
    const review = page.waitForResponse((res) => new URL(res.url()).pathname === '/review_state');
    await page.goto(href);
    await review;
    await expectSignedIn(page);
    expect(requests.get()).toBe(1);
    expect(requests.get('/review_state')).toBe(1);

    // The deferred re-check is still due, and the next ordinary page pays it.
    const recheck = page.waitForResponse((res) => new URL(res.url()).pathname === '/user_list_state');
    await page.goto('/rankings');
    await recheck;
    expect(requests.get('/user_list_state')).toBe(1);
  });

  test('adding to a list from a book page right after sign-in works', async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    const href = await openFirstBookPage(page);
    // Sign-in lands on a book page with no entry and no re-check (the page
    // already costs a request); the widget must still work from there.
    await page.evaluate(() => {
      Object.keys(localStorage)
        .filter((k) => k.startsWith('tg:user_list_state:'))
        .forEach((k) => localStorage.removeItem(k));
    });
    await page.goto(href);
    await expectSignedIn(page);

    const widget = page.getByRole('button', { name: /Add to list/i }).first();
    await widget.click();
    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const row = modal.getByRole('checkbox').first();
    // A checked row here would make check() a no-op and the test vacuous.
    await expect(row).not.toBeChecked();
    await row.check();
    await expect(row).toBeChecked();
    await page.keyboard.press('Escape');

    const requests = countStateRequests(page);
    await page.reload();
    await expect(page.getByRole('button', { name: /On \d+ list/i }).first()).toBeVisible();
    expect(requests.get('/user_list_state')).toBe(0);

    // Leave the account as we found it.
    await page.getByRole('button', { name: /On \d+ list/i }).first().click();
    await expect(modal).toBeVisible();
    await modal.getByRole('checkbox').first().uncheck();
    await expect(modal.getByRole('checkbox').first()).not.toBeChecked();
  });

  test("a different user on the same browser never sees the first user's state", async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    const first = await cachedEntry(page);
    expect(first?.user_id).toBeTruthy();
    const firstListIds = (first!.lists as { id: number }[]).map((l) => l.id);
    expect(firstListIds.length).toBeGreaterThan(0);

    await page.locator('#navbar_login_button').click();
    await expectSignedOut(page);

    await signIn(page, credentials('MEMBER'));
    await page.goto('/rankings');
    await expectSignedIn(page);
    await expect.poll(() => cachedEntry(page), { timeout: 15_000 }).not.toBeNull();

    const second = (await cachedEntry(page))!;
    expect(second.user_id).not.toBe(first!.user_id);
    const secondListIds = (second.lists as { id: number }[]).map((l) => l.id);
    expect(secondListIds.filter((id) => firstListIds.includes(id))).toEqual([]);
  });
});
