import { test, expect } from '@playwright/test';

// This spec depends on the e2e-admin account having a healthy body of reviews to
// filter/sort/page through. As of writing that account has 30 Books::Book reviews
// (ratings cycling 1-5 evenly, alternating written/rating-only), seeded once via a
// targeted, additive `bin/rails runner` script -- see task-11-report.md for the
// exact script. One of those, "Animal Farm", has a title no other seeded review
// shares, which is what makes it a safe, exact search term below.
const SEARCH_TITLE = 'Animal Farm';
const SEEDED_MINIMUM = 30;

test.describe('My Reviews', () => {
  test('renders and shows a total count', async ({ page }) => {
    await page.goto('/my/reviews');

    await expect(page.getByRole('heading', { name: 'My Reviews', level: 1 })).toBeVisible();

    const total = Number((await page.getByTestId('my-reviews-total').innerText()).trim());
    // A lower bound, not an exact match: other specs in this directory (e.g.
    // reviews-write.spec.ts) transiently add and remove a review of their own
    // elsewhere in the same account during a full suite run.
    expect(total).toBeGreaterThanOrEqual(SEEDED_MINIMUM);
  });

  test('clicking a rating bar filters, and the URL carries the rating', async ({ page }) => {
    await page.goto('/my/reviews');

    const bar = page.getByTestId('rating-bar-3');
    // Read the bar's own displayed count rather than assuming a fixed seed number --
    // the dialog-edit test below permanently rotates one seeded review's rating, so
    // the exact per-rating counts drift across repeated runs of this suite.
    const expectedCount = Number((await bar.locator('.tabular-nums').innerText()).trim());
    expect(expectedCount).toBeGreaterThan(0);

    await bar.click();

    await expect(page).toHaveURL(/[?&]rating=3(&|$)/);
    await expect(page.getByTestId('rating-bar-3')).toHaveAttribute('aria-current', 'true');

    const rowTriggers = page.locator('[data-testid="edit-review"], [data-testid="write-review"]');
    await expect(rowTriggers).toHaveCount(expectedCount);

    // Every visible row is genuinely rated 3 -- not just a URL that says so.
    const stars = page.getByRole('img', { name: /out of 5 stars/ });
    await expect(stars).toHaveCount(expectedCount);
    for (const star of await stars.all()) {
      await expect(star).toHaveAttribute('aria-label', '3.0 out of 5 stars');
    }
  });

  test('changing the sort re-orders the rows', async ({ page }) => {
    await page.goto('/my/reviews');

    await page.getByLabel('Sort your reviews').selectOption({ label: 'My rating: high to low' });

    await expect(page).toHaveURL(/[?&]sort=rating_high(&|$)/);

    // A real reorder check, not just "the array changed": every row's own rating
    // (read from the accessible star label, not assumed) must be non-increasing.
    const ratings = await page.getByRole('img', { name: /out of 5 stars/ }).evaluateAll(
      (nodes) => nodes.map((node) => parseFloat(node.getAttribute('aria-label') ?? '0'))
    );
    expect(ratings.length).toBeGreaterThan(1);
    for (let i = 1; i < ratings.length; i++) {
      expect(ratings[i]).toBeLessThanOrEqual(ratings[i - 1]);
    }
  });

  test('paging forward moves to the next page of reviews', async ({ page }) => {
    // Only meaningful because the seeded account has 30 reviews against a 25-per-page
    // limit (MyReviewsController::PER_PAGE) -- if it ever drops to 25 or fewer this
    // assertion would pass vacuously, so it is written to fail loudly instead: it
    // requires the next-page link to exist and the row count to actually shrink.
    await page.goto('/my/reviews');

    const rowTriggers = page.locator('[data-testid="edit-review"], [data-testid="write-review"]');
    await expect(rowTriggers).toHaveCount(25);

    const firstPageLead = await page.locator('a[href^="/book/"]').first().getAttribute('href');

    const nextLink = page.locator('nav.pagy a[href="/my/reviews/page/2"]').first();
    await expect(nextLink).toBeVisible();
    await nextLink.click();

    await expect(page).toHaveURL(/\/my\/reviews\/page\/2$/);
    await expect(rowTriggers).toHaveCount(5);

    const secondPageLead = await page.locator('a[href^="/book/"]').first().getAttribute('href');
    expect(secondPageLead).not.toEqual(firstPageLead);
  });

  // The regression this guards: reviews/my_reviews_controller.js#submitted() listens
  // document-wide for turbo:submit-end (the review dialog lives outside its own
  // container), but turbo:submit-end also bubbles from this page's own GET search
  // form. An earlier version reloaded on ANY successful submit reaching document,
  // which reloaded the pre-search URL and silently discarded the query. The fix
  // guards the reload to `event.target.closest?.("#review_modal")`. Neither branch
  // of that guard had ever been exercised in a real browser before this spec.
  test('submitting the search box filters results and keeps the query -- it must NOT reload away', async ({page}) => {
    await page.goto('/my/reviews');

    const searchInput = page.getByLabel('Search your reviews');
    await searchInput.fill(SEARCH_TITLE);
    await page.getByRole('button', { name: 'Search' }).click();

    // If the reload guard regressed, this URL would fall back to the pre-search
    // "/my/reviews" with no query -- assert the query actually survived.
    await expect(page).toHaveURL(/[?&]q=Animal(?:\+|%20)Farm(&|$)/);
    await expect(searchInput).toHaveValue(SEARCH_TITLE);

    // And the results are genuinely filtered, not the full unfiltered list a lost
    // query would have produced.
    const rowTriggers = page.locator('[data-testid="edit-review"], [data-testid="write-review"]');
    await expect(rowTriggers).toHaveCount(1);
    // Each row renders two links to the same book (a cover-image link and a title
    // link); .last() is the title link, in source order after the image.
    await expect(page.getByRole('link', { name: SEARCH_TITLE, exact: true }).last()).toBeVisible();
  });

  test('opening the dialog from a row, changing the rating and saving reloads the row with the new value', async ({page}) => {
    await page.goto('/my/reviews');

    const trigger = page.getByTestId('edit-review').first();
    await expect(trigger).toBeVisible();
    const currentRating = Number(await trigger.getAttribute('data-rating'));
    const newRating = (currentRating % 5) + 1; // always different, wraps 5 -> 1

    await trigger.click();
    await expect(page.locator('#review_modal')).toBeVisible();

    await page.getByTestId('review-star-button').nth(newRating - 1).click();
    await page.getByRole('button', { name: 'Save' }).click();

    // ReviewsController's turbo-stream response targets book-page element ids that
    // don't exist on /my/reviews, so a real reload -- not a Turbo Stream update -- is
    // what has to carry the new rating onto the row. Confirming the dialog closes and
    // the SAME row now reports the new rating proves the reload guard fired for this
    // submission (the other spec in this file proves it does NOT fire for a search).
    await expect(page.locator('#review_modal')).not.toBeVisible();
    await expect(page.getByTestId('edit-review').first()).toHaveAttribute('data-rating', String(newRating));
  });
});
