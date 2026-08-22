import { test, expect } from '@playwright/test';

test.describe('Books news', () => {
  test('the index loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/news');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'News', level: 1 })).toBeVisible();
  });

  test('a card links through to the post page', async ({ page }) => {
    await page.goto('/news');

    const firstPost = page.locator('article h2 a').first();
    const title = (await firstPost.textContent())?.trim() ?? '';
    await firstPost.click();

    await expect(page).toHaveURL(/\/news\/[a-z0-9-]+$/);
    await expect(page.getByRole('heading', { name: title, level: 1 })).toBeVisible();
  });

  test('a post page renders formatted body text', async ({ page }) => {
    await page.goto('/news');
    await page.locator('article h2 a').first().click();

    // The body renders through BodyRenderer, so it is real markup rather than
    // the raw Markdown source.
    await expect(page.locator('.prose')).toBeVisible();
    await expect(page.locator('.prose')).not.toContainText('**');
  });

  test('a post page carries Open Graph tags', async ({ page }) => {
    await page.goto('/news');
    const title = (await page.locator('article h2 a').first().textContent())?.trim() ?? '';
    await page.locator('article h2 a').first().click();

    await expect(page.locator('meta[property="og:type"]')).toHaveAttribute('content', 'article');
    // Strengthened from `not.toHaveAttribute('content', '')`: the books
    // layout falls back og:title to the page's <title> when show.html.erb
    // sets none, and that fallback is itself never empty -- the index page
    // renders "News | The Greatest Books" for it before this test ever
    // clicks anything. A bare non-empty check was therefore already true
    // pre-click and could not fail if show.html.erb's own
    // `content_for :og_title` were removed. Asserting the exact post title
    // only holds if the post page actually sets it.
    await expect(page.locator('meta[property="og:title"]')).toHaveAttribute('content', title);
  });

  // F3 (R70): the task text's original version of this test clicked the
  // FIRST post and asserted `h1` count === 1. The first post in development
  // is "december-update" (it is the newest, per the corrections table), and
  // its only body heading is "## Hey everyone" -- a double hash. The shift
  // is "# -> h2, ## -> h3, ### -> h4", so "##" renders <h3> with the shift
  // working and <h2> with it removed. Neither is an <h1>, so that assertion
  // passed whether shift_headings worked, was broken, or was deleted -- it
  // could not fail. "major-ranking-changes" is the only development post
  // whose body opens with a SINGLE "#".
  test('a body heading is shifted below the page title', async ({ page }) => {
    // The h1 count below is a page-structure check, NOT the heading-shift
    // check: BodyRenderer's ALLOWED_TAGS excludes h1 entirely, so when the
    // shift is disabled the sanitizer STRIPS a would-be second h1 down to
    // plain text rather than rendering it. Measured on this post: with the
    // shift, 0 h1 / 3 h2; without it, 0 h1 / 0 h2 -- the h1 count alone
    // cannot tell the two apart. "Exactly one h1 on the page" is still a
    // real, independent page-structure property worth asserting (it would
    // fail if the layout or template ever grew a genuine second h1), but the
    // h2 assertion below -- pinned to the shifted heading's own text -- is
    // the one that actually catches a broken or removed shift.
    await page.goto('/news/major-ranking-changes');

    await expect(page.locator('h1')).toHaveCount(1);
    await expect(page.locator('.prose h2').first()).toHaveText('List Date Penalty Feature');
  });

  test('the legacy blog post url redirects', async ({ page }) => {
    await page.goto('/blog_posts/december-update');

    await expect(page).toHaveURL(/\/news\/december-update$/);
  });

  // F2 (R57): renamed from "a draft is not reachable at its public url",
  // which could not fail. Development has 31 posts, all published, and no
  // draft at all, so "/news/something-unfinished" 404s because the record
  // is absent -- not because it is unpublished. That is what a working
  // draft gate AND a completely absent draft gate both produce. The real
  // draft check lives in e2e/tests/books/admin/news.spec.ts, where a draft
  // is created with a managed lifetime and reached at its real public URL.
  test('an unknown slug 404s', async ({ page }) => {
    const response = await page.goto('/news/no-such-post-exists');

    expect(response?.status()).toBe(404);
  });

  // F4 (R71): development has zero books news topics, so no topic-filter
  // test is added here -- it would fail against correct code (see the
  // corrections doc). Pagination reaches page 2 for the first time now that
  // there are 31 posts across 4 pages at PER_PAGE = 10, and path-based
  // paging is a standing landmine in this codebase.
  test('pagination is path based and reaches page 2', async ({ page }) => {
    await page.goto('/news');
    const firstTitle = await page.locator('article h2 a').first().textContent();

    // Matched against href rather than the anchor's text: the rendered
    // pagy nav also has "<" and ">" anchors, and href is exact rather than
    // a substring match, matching the sibling convention in lists.spec.ts.
    await page.locator('nav.pagy a[href="/news/page/2"]').first().click();

    await expect(page).toHaveURL(/\/news\/page\/2$/);
    const secondTitle = await page.locator('article h2 a').first().textContent();
    expect(secondTitle).not.toBe(firstTitle); // proves the page actually changed
  });
});
