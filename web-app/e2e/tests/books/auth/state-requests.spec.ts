import { test, expect, type Page } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';
import { expectSignedIn, expectSignedOut } from '../../../support/sign-in-state';
import { ageCache, cachedEntry, countStateRequests, settle } from '../../../support/state-requests';

// A signed-in page load makes at most one Rails state request, and usually none:
// the per-user state is cached in localStorage and re-checked hourly. Each test
// signs in for real because Firebase's IndexedDB is not part of storage state.
test.use({ storageState: { cookies: [], origins: [] } });

const HOUR = 60 * 60 * 1000;
const ORDINARY_PAGES = ['/', '/rankings', '/lists'];

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
  const card = page.locator('[data-listable-type="Books::Book"]').first();
  const id = await card.getAttribute('data-listable-id');
  const href = await card.locator('a').first().getAttribute('href');
  expect(id).toBeTruthy();
  expect(href).toBeTruthy();
  return { href: href!, id: id! };
}

// This book's own widget; a page can carry several (related books, etc.).
function widgetFor(page: Page, id: string) {
  return page.locator(
    `[data-controller="user-list-widget"][data-user-list-widget-listable-type-value="Books::Book"][data-user-list-widget-listable-id-value="${id}"]`
  );
}

test.describe('Per-user state requests (books)', () => {
  test('ordinary pages make no state requests within the hour', async ({ page }) => {
    await signInAndFillCache(page, 'USER');

    const requests = countStateRequests(page);
    for (const path of ORDINARY_PAGES) {
      await page.goto(path);
      await expectSignedIn(page);
    }
    await settle(page);
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

    await settle(page);
    expect(requests.get()).toBe(1);
    expect(requests.requests('/user_list_state')[0].headers()['if-none-match']).toBeTruthy();
    // Nothing changed, so the server must say so rather than resend the body.
    expect(stateResponse.status()).toBe(304);

    // The re-check restamps the entry, so the next page is free again.
    await page.goto('/lists');
    await expectSignedIn(page);
    await settle(page);
    expect(requests.get()).toBe(1);
  });

  test('the Members link shows without a /membership_state request', async ({ page }) => {
    await signInAndFillCache(page, 'MEMBER');

    const requests = countStateRequests(page);
    await page.goto('/rankings');
    await expect(page.locator('#navbar_members:visible')).not.toHaveCount(0);
    await settle(page);
    expect(requests.get('/membership_state')).toBe(0);
    expect(requests.get()).toBe(0);
  });

  test('a book page makes exactly one state request even when the re-check is due', async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    const { href } = await openFirstBookPage(page);
    await ageCache(page, HOUR + 60_000);

    const requests = countStateRequests(page);
    const review = page.waitForResponse((res) => new URL(res.url()).pathname === '/review_state');
    await page.goto(href);
    await review;
    await expectSignedIn(page);
    await settle(page);
    expect(requests.get()).toBe(1);
    expect(requests.get('/review_state')).toBe(1);

    // The deferred re-check is still due, and the next ordinary page pays it.
    const recheck = page.waitForResponse((res) => new URL(res.url()).pathname === '/user_list_state');
    await page.goto('/rankings');
    await recheck;
    await settle(page);
    expect(requests.get('/user_list_state')).toBe(1);
  });

  test('adding to a list from a book page right after sign-in works', async ({ page }) => {
    await signInAndFillCache(page, 'USER');
    const { href, id } = await openFirstBookPage(page);
    // Sign-in lands on a book page with no entry and no re-check (the page
    // already costs a request); the widget must still work from there.
    await page.evaluate(() => {
      Object.keys(localStorage)
        .filter((k) => k.startsWith('tg:user_list_state:'))
        .forEach((k) => localStorage.removeItem(k));
    });
    await page.goto(href);
    await expectSignedIn(page);

    const widget = widgetFor(page, id);
    await widget.getByRole('button').click();
    const modal = page.locator('#user_list_modal');
    await expect(modal).toBeVisible();
    const row = modal.locator('input[data-list-id]').first();
    await expect(row).toBeVisible();
    // A checked row here would make check() a no-op and the test vacuous.
    await expect(row).not.toBeChecked();
    const listId = Number(await row.getAttribute('data-list-id'));

    // The write must succeed on the server, not just flip the box locally.
    const created = page.waitForResponse(
      (res) => res.request().method() === 'POST' && new URL(res.url()).pathname === `/user_lists/${listId}/items`
    );
    await row.check();
    expect((await created).status()).toBe(201);
    await expect(row).toBeChecked();
    await page.keyboard.press('Escape');

    const requests = countStateRequests(page);
    await page.reload();
    await expectSignedIn(page);
    await expect(widget.getByRole('button', { name: /On \d+ list/i })).toBeVisible();
    const memberOf = (await cachedEntry(page))?.memberships?.['Books::Book']?.[id] as { list_id: number }[] | undefined;
    expect((memberOf ?? []).map((m) => m.list_id)).toContain(listId);
    await settle(page);
    expect(requests.get('/user_list_state')).toBe(0);

    // Leave the account as we found it, through this book's widget only.
    await widget.getByRole('button').click();
    await expect(modal).toBeVisible();
    const sameRow = modal.locator(`input[data-list-id="${listId}"]`);
    await expect(sameRow).toBeChecked();
    const removed = page.waitForResponse(
      (res) => res.request().method() === 'DELETE' && new URL(res.url()).pathname.startsWith(`/user_lists/${listId}/items/`)
    );
    await sameRow.uncheck();
    expect((await removed).ok()).toBe(true);
    await expect(sameRow).not.toBeChecked();
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
    await page.goto(ORDINARY_PAGES[0]);
    await expectSignedIn(page);
    await expect.poll(() => cachedEntry(page), { timeout: 15_000 }).not.toBeNull();

    const second = (await cachedEntry(page))!;
    expect(second.user_id).not.toBe(first!.user_id);
    const secondListIds = (second.lists as { id: number }[]).map((l) => l.id);
    expect(secondListIds.filter((id) => firstListIds.includes(id))).toEqual([]);

    // The DOM, not just the cache: B's list modal offers only B's own lists.
    const modalListIds = async () => {
      await page.locator('[data-controller="user-list-widget"] button:visible').first().click();
      const modal = page.locator('#user_list_modal');
      await expect(modal).toBeVisible();
      const ids = await modal.locator('input[data-list-id]').evaluateAll((els) =>
        els.map((el) => Number((el as HTMLElement).dataset.listId))
      );
      await page.keyboard.press('Escape');
      return ids;
    };
    const shownIds = await modalListIds();
    expect(shownIds.length).toBeGreaterThan(0);
    expect(shownIds.filter((id) => firstListIds.includes(id))).toEqual([]);

    // A cookie-only switch: A's entry is left in localStorage while tg_uid says
    // B. The user_id guard (sign-out and sign-in clear storage, bypassing it)
    // must discard it on the next load rather than render it.
    await page.evaluate((entry) => {
      localStorage.setItem(`tg:user_list_state:${document.body.dataset.domain}`, JSON.stringify(entry));
    }, first);
    await page.goto(ORDINARY_PAGES[1]);
    await expectSignedIn(page);
    await expect.poll(async () => (await cachedEntry(page))?.user_id).toBe(second.user_id);
    const afterSwitch = (await cachedEntry(page))!;
    expect((afterSwitch.lists as { id: number }[]).map((l) => l.id)).toEqual(secondListIds);
  });
});
