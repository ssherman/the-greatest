import { test, expect } from '@playwright/test';

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
    await page.goto('/the-greatest/novels/books');
    await page.getByRole('button', { name: 'Filters' }).click();

    const others = page.locator('input[name="category_slugs[]"]:not([value="novels"])');
    await others.first().waitFor();
    const second = await others.first().getAttribute('value');

    await stubChallenge(page, (url) => url.pathname === '/filters');

    await others.first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('stub-challenge')).toBeVisible();

    const landed = decodeURIComponent(page.url());
    expect(landed).toContain('/filters?');
    expect(landed).toContain('category_slugs[]=novels');
    expect(landed).toContain(`category_slugs[]=${second}`);
  });
});
