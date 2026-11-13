import { test, expect } from '@playwright/test';

// The sitemap index, its first child file and the robots.txt Sitemap line, as
// a crawler fetches them. Whether every listed URL is indexable is pinned by
// test/integration/sitemap_consistency_test.rb; this checks the served files.
// The games side is e2e/tests/games/sitemap.spec.ts.
test.describe('Music sitemap', () => {
  test('the index links child files that serve a urlset', async ({ request }) => {
    const index = await request.get('/sitemap.xml');
    expect(index.status()).toBe(200);
    const body = await index.text();
    expect(body).toContain('<sitemapindex');

    const firstChild = body.match(/<loc>([^<]+)<\/loc>/)?.[1];
    expect(firstChild).toBeTruthy();
    const child = await request.get(firstChild!);
    expect(child.status()).toBe(200);
    expect(await child.text()).toContain('<urlset');
  });

  test('robots.txt points at the sitemap', async ({ request }) => {
    const robots = await request.get('/robots.txt');
    expect(robots.status()).toBe(200);
    expect(await robots.text()).toContain('Sitemap:');
  });
});
