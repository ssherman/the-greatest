import { test, expect } from '@playwright/test';

declare global {
  interface Window {
    __notReloaded?: boolean;
  }
}

const CHALLENGE_BODY =
  '<html><body><h1 data-testid="stub-challenge">Just a moment...</h1></body></html>';

async function stubChallenge(
  page: import('@playwright/test').Page,
  matcher: Parameters<import('@playwright/test').Page['route']>[0],
) {
  await page.route(matcher, (route) =>
    route.fulfill({
      status: 403,
      contentType: 'text/html',
      headers: { 'cf-mitigated': 'challenge' },
      body: CHALLENGE_BODY,
    }),
  );
}

test.describe('Cloudflare challenge hand-off', () => {
  test('a challenged filter navigation takes the whole page to the challenged URL', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();

    await page.getByRole('button', { name: /Category/ }).click();
    const genre = page.locator("input[name='category_slugs[]'][value='fiction']");
    await genre.waitFor();
    await genre.check();

    await stubChallenge(page, (url) => url.pathname === '/filters');

    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('stub-challenge')).toBeVisible();

    const landed = decodeURIComponent(page.url());
    expect(landed).toContain('/filters?');
    expect(landed).toContain('category_slugs[]=fiction');
  });

  async function expectReload(
    page: import('@playwright/test').Page,
    trigger: () => Promise<unknown>,
  ) {
    await page.evaluate(() => {
      window.__notReloaded = true;
    });

    const load = page.waitForEvent('load');
    await trigger();
    await load;

    expect(await page.evaluate(() => window.__notReloaded ?? null)).toBeNull();
  }

  test('a challenged frame load reloads the current page instead of navigating to the frame URL', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/filters/categories', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { headers: { Accept: 'text/html', 'Turbo-Frame': 'books_filter_pane_category' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  test('a challenged JSON fetch reloads the current page', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/filters/categories', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { headers: { Accept: 'application/json' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  test('a challenged POST reloads the current page instead of navigating to the endpoint', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/user_lists', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { method: 'POST', headers: { Accept: 'text/html' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  // Turbo 8 fetches a hovered link after 100ms and caches that FetchRequest
  // whatever the response was, then replays it on the click without calling
  // window.fetch -- so the hand-off wrapper never sees the click. The layouts
  // switch prefetch off; the pause is long enough that a hover which was going
  // to prefetch has already done so.
  const HOVER_SETTLE_MS = 500;

  async function firstBookLink(page: import('@playwright/test').Page) {
    const link = page.locator('main a[href^="/book/"]').first();
    await link.waitFor();
    const href = await link.getAttribute('href');
    return { link, target: new URL(href!, page.url()).href };
  }

  test('hovering a link does not fetch it', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const { link, target } = await firstBookLink(page);

    let hits = 0;
    page.on('request', (request) => {
      if (request.url() === target) hits += 1;
    });

    await link.hover();
    await page.waitForTimeout(HOVER_SETTLE_MS);

    expect(hits).toBe(0);
    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  test('a link hovered before it is clicked still hands the whole page off when challenged', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const { link, target } = await firstBookLink(page);
    await stubChallenge(page, target);

    await link.hover();
    await page.waitForTimeout(HOVER_SETTLE_MS);

    await expectReload(page, () => link.click());

    await expect(page).toHaveURL(target);
    await expect(page.getByTestId('stub-challenge')).toBeVisible();
  });

  test('the same URL does not hand off twice inside the guard window', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/the-greatest/classics/books', page.url()).href;
    await stubChallenge(page, target);

    await page.evaluate(
      ([key, url]) => {
        sessionStorage.setItem(key, JSON.stringify({ url, at: Date.now() }));
      },
      ['cf-challenge-handoff', target],
    );

    const status = await page.evaluate(async (url) => {
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      return response.status;
    }, target);

    expect(status).toBe(403);
    await expect(page.getByTestId('stub-challenge')).toHaveCount(0);
    await expect(page).toHaveURL('/the-greatest/novels/books');
  });
});
