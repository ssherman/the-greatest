import { test, expect, type Page } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';
import { expectSignedIn, expectSignedOut } from '../../../support/sign-in-state';
import { ageCache, cachedEntry, countStateRequests } from '../../../support/state-requests';

// A signed-in page load makes at most one Rails state request, and usually none:
// the per-user state is cached in localStorage and re-checked hourly. Each test
// signs in for real because Firebase's IndexedDB is not part of storage state.
test.use({ storageState: { cookies: [], origins: [] } });

const HOUR = 60 * 60 * 1000;
const ORDINARY_PAGES = ['/rankings', '/songs', '/'];

// Fills the cache entry: the first ordinary page after sign-in is the one that
// has to ask. Waiting on the entry (not a sleep) is what makes later counts exact.
async function signInAndFillCache(page: Page) {
  await signIn(page, credentials('ADMIN'));
  await page.goto('/');
  await expectSignedIn(page);
  await expect.poll(() => cachedEntry(page), { timeout: 15_000 }).not.toBeNull();
}

test.describe('Per-user state requests (music)', () => {
  test('ordinary pages make no state requests within the hour', async ({ page }) => {
    await signInAndFillCache(page);

    const requests = countStateRequests(page);
    for (const path of ORDINARY_PAGES) {
      await page.goto(path);
      await expectSignedIn(page);
    }
    expect(requests.get()).toBe(0);
  });

  test('an aged cache makes exactly one conditional request, answered with a 304', async ({ page }) => {
    await signInAndFillCache(page);
    await ageCache(page, HOUR + 60_000);

    const requests = countStateRequests(page);
    const response = page.waitForResponse((res) => new URL(res.url()).pathname === '/user_list_state');
    await page.goto(ORDINARY_PAGES[0]);
    await expectSignedIn(page);
    const stateResponse = await response;

    expect(requests.get()).toBe(1);
    expect(requests.requests('/user_list_state')[0].headers()['if-none-match']).toBeTruthy();
    // Nothing changed, so the server must say so rather than resend the body.
    expect(stateResponse.status()).toBe(304);

    // The re-check restamps the entry, so the next page is free again.
    await page.goto(ORDINARY_PAGES[1]);
    await expectSignedIn(page);
    expect(requests.get()).toBe(1);
  });

  test('the Members link needs no /membership_state request', async ({ page }) => {
    await signInAndFillCache(page);

    // The admin account is not a member, so the link stays hidden; what matters
    // is that the cached entry carries the answer and nothing asked for it.
    const entry = await cachedEntry(page);
    expect(entry?.membership?.member).toBe(false);

    const requests = countStateRequests(page);
    await page.goto(ORDINARY_PAGES[0]);
    await expectSignedIn(page);
    await expect(page.locator('#navbar_members').first()).toHaveClass(/hidden/);
    expect(requests.get('/membership_state')).toBe(0);
    expect(requests.get()).toBe(0);
  });

  test("a different user on the same browser never sees the first user's state", async ({ page }) => {
    await signInAndFillCache(page);
    const first = await cachedEntry(page);
    expect(first?.user_id).toBeTruthy();
    const firstListIds = (first!.lists as { id: number }[]).map((l) => l.id);
    expect(firstListIds.length).toBeGreaterThan(0);

    await page.locator('#navbar_login_button').click();
    await expectSignedOut(page);

    await signIn(page, credentials('USER'));
    await page.goto(ORDINARY_PAGES[0]);
    await expectSignedIn(page);
    await expect.poll(() => cachedEntry(page), { timeout: 15_000 }).not.toBeNull();

    const second = (await cachedEntry(page))!;
    expect(second.user_id).not.toBe(first!.user_id);
    const secondListIds = (second.lists as { id: number }[]).map((l) => l.id);
    expect(secondListIds.filter((id) => firstListIds.includes(id))).toEqual([]);
  });
});
