import { test, expect } from '@playwright/test';

// the-great-gatsby is the most-reviewed book in the migrated corpus: 450 ratings and
// 37 written reviews as of the 2026-08-10 production migration.
const REVIEWED_BOOK = '/book/the-great-gatsby';

// One of the 118 migrated bodies containing a <spoiler> tag.
const SPOILER_BOOK = '/book/room-for-murder';

test.describe('Book page ratings and reviews', () => {
  test('a rated book shows the summary line and the reviews card', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    const summaryLine = page.getByTestId('review-summary-line');
    await expect(summaryLine).toBeVisible();
    await expect(summaryLine).toContainText('ratings');

    await expect(page.locator('#ratings-reviews')).toBeVisible();
    await expect(page.getByTestId('rating-histogram').getByTestId('histogram-row')).toHaveCount(5);
    expect(await page.getByTestId('review').count()).toBeGreaterThan(1);
  });

  test('the summary line jumps to the reviews card', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    await page.getByTestId('review-summary-line').click();

    await expect(page).toHaveURL(/#ratings-reviews$/);
    await expect(page.locator('#ratings-reviews')).toBeInViewport();
  });

  test('reviews are listed newest first', async ({ page }) => {
    await page.goto(REVIEWED_BOOK);

    const stamps = await page.getByTestId('review').locator('time').evaluateAll(
      (nodes) => nodes.map((node) => node.getAttribute('datetime') ?? '')
    );

    expect(stamps.length).toBeGreaterThan(1);
    expect(stamps).toEqual([...stamps].sort().reverse());
  });

  test('a spoiler stays blurred until it is clicked', async ({ page }) => {
    await page.goto(SPOILER_BOOK);

    const spoiler = page.locator('.review-spoiler').first();
    await expect(spoiler).toBeVisible();
    await expect(spoiler).toHaveAttribute('role', 'button');
    await expect(spoiler).not.toHaveClass(/review-spoiler--revealed/);

    await spoiler.click();

    // A revealed spoiler drops its button semantics entirely -- no role, no tabindex,
    // no aria-label -- rather than flipping aria-expanded. There is no toggle back to
    // blurred, so reviews/spoiler_controller.js#showSpoiler treats aria-expanded as a
    // stray attribute it would otherwise have to describe a state change that never
    // reverses, and never sets it.
    await expect(spoiler).toHaveClass(/review-spoiler--revealed/);
    await expect(spoiler).not.toHaveAttribute('role');
  });

  test('a spoiler can be revealed from the keyboard', async ({ page }) => {
    await page.goto(SPOILER_BOOK);

    const spoiler = page.locator('.review-spoiler').first();
    await spoiler.focus();
    await page.keyboard.press('Enter');

    await expect(spoiler).toHaveClass(/review-spoiler--revealed/);
  });

  test('an unrated book shows no rating surface', async ({ page }) => {
    // Book 200, verified to have no review_summary row. 72,659 of the 126,289 books
    // have never been rated, so this is the common case, not an edge case.
    await page.goto('/book/nightmare-abbey');

    await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
    await expect(page.getByTestId('review-summary-line')).toHaveCount(0);
    await expect(page.locator('#ratings-reviews')).toHaveCount(0);
  });

  test('a signed-out visitor is asked to sign in before rating', async ({ page }) => {
    await page.goto('/book/the-great-gatsby');

    await page.getByTestId('review-widget-label').click();

    await expect(page.locator('#review_modal')).not.toBeVisible();
    await expect(page.locator('#login_modal')).toBeVisible();
  });
});
