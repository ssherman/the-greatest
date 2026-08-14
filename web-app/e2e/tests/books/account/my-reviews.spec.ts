import { test, expect } from '@playwright/test';

// This spec depends on the e2e-admin account having a healthy body of reviews to
// filter/sort/page through. Run `bin/rails e2e:my_reviews` (lib/tasks/e2e.rake)
// first -- it idempotently seeds 30 Books::Book reviews for that account (6 per
// rating, alternating written/rating-only, avoiding the 3 book slugs other specs
// in this directory depend on). One of those 30, "Animal Farm", has a title no
// other seeded review shares, which is what makes it a safe, exact search term
// below.
const SEARCH_TITLE = 'Animal Farm';
// Exact, not a lower bound: playwright.config.ts runs with workers: 1 and
// fullyParallel: false, so spec files run strictly sequentially in this worker,
// and no other spec in this directory leaves a permanent Books::Book review
// behind on this account (reviews-write.spec.ts always removes what it creates,
// in its own afterEach, on a book excluded from this seed).
const SEEDED_COUNT = 30;

test.describe('My Reviews', () => {
  test('renders and shows a total count', async ({ page }) => {
    await page.goto('/my/reviews');

    await expect(page.getByRole('heading', { name: 'My Reviews', level: 1 })).toBeVisible();

    const total = Number((await page.getByTestId('my-reviews-total').innerText()).trim());
    expect(total).toBe(SEEDED_COUNT);
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

  // This permanently rotates whichever review is currently first among
  // `edit-review` rows to a different rating on every run, and never restores it
  // -- unlike reviews-write.spec.ts, which creates a review and removes it again
  // in its own afterEach. There is no "original" rating to restore here: this
  // row is itself seed data with an arbitrary rating to begin with, and
  // `(currentRating % 5) + 1` is self-consistent and deterministic across
  // repeated runs, so leaving the rotation in place is intentional, not an
  // oversight.
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

  // Deleting from a row is destructive and irreversible, so this test creates its
  // own review to destroy rather than touching the seeded 30 -- on the one book
  // e2e:my_reviews deliberately excludes. The afterEach is a safety net for a
  // mid-test failure: without it a crashed run would leave a 31st review behind
  // and the exact-count assertion at the top of this file would fail on every
  // later run, for a reason nowhere near where it broke.
  test.describe('deleting from a row', () => {
    const SCRATCH_BOOK = '/book/nightmare-abbey';

    // Clean up by IDENTITY, not by counting rows. MyReviewsController::PER_PAGE
    // is 25, so /my/reviews can never show more than 25 delete buttons -- a
    // "more than SEEDED_COUNT (30) buttons" test can never be true, and an
    // earlier version of this hook was therefore dead code that looked like a
    // safety net. The scratch review is always reachable on page 1 because the
    // default sort is newest-first and this review was just created.
    test.afterEach(async ({ page }) => {
      // Drop any request interception the test left armed. A test that fails
      // midway never reaches its own unroute, and a still-active 429 stub would
      // make this cleanup silently unable to delete anything -- observed while
      // verifying the failure test below.
      await page.unrouteAll();

      await page.goto('/my/reviews');
      const scratchRow = page.locator('li', { has: page.locator(`a[href="${SCRATCH_BOOK}"]`) });

      while (await scratchRow.count() > 0) {
        page.once('dialog', (d) => d.accept());
        await scratchRow.first().getByTestId('delete-review').click();
        await expect(page.locator(`a[href="${SCRATCH_BOOK}"]`)).toHaveCount(0);
      }
    });

    test('a row can be deleted directly, after confirming', async ({ page }) => {
      // Create the review to delete, through the normal book-page write flow.
      await page.goto(SCRATCH_BOOK);
      await page.getByTestId('review-widget-label').click();
      await expect(page.locator('#review_modal')).toBeVisible();
      await page.getByTestId('review-star-button').nth(2).click();
      await page.getByRole('button', { name: 'Save' }).click();
      await expect(page.locator('#review_modal')).not.toBeVisible();

      await page.goto('/my/reviews');
      await expect(page.getByTestId('my-reviews-total')).toHaveText(String(SEEDED_COUNT + 1));

      // The row for the scratch book, identified by its link rather than position,
      // so a sort change elsewhere can never make this delete the wrong review.
      const row = page.locator('li', { has: page.locator(`a[href="${SCRATCH_BOOK}"]`) }).first();
      await expect(row).toBeVisible();

      // Dismissing the confirmation must leave the review alone -- a delete that
      // fires anyway is worse than no confirmation at all, because the prompt
      // tells the user they still have a choice.
      page.once('dialog', (d) => d.dismiss());
      await row.getByTestId('delete-review').click();
      await expect(page.getByTestId('my-reviews-total')).toHaveText(String(SEEDED_COUNT + 1));

      page.once('dialog', (d) => {
        expect(d.message()).toContain('cannot be undone');
        d.accept();
      });
      await row.getByTestId('delete-review').click();

      await expect(page.locator(`a[href="${SCRATCH_BOOK}"]`)).toHaveCount(0);
      await expect(page.getByTestId('my-reviews-total')).toHaveText(String(SEEDED_COUNT));
    });

    // ReviewsController answers every deliberate failure with an EMPTY turbo
    // stream carrying only a status, and a row's delete form -- unlike the
    // dialog -- has no inline error line of its own. So a failed delete used to
    // do nothing observable at all: the row stayed, no message, button looks
    // broken. The 429 is the reachable one: the write limit is 20 a minute and
    // DELETE counts, which is easy to hit while clearing out old ratings.
    test('a delete that fails says so instead of silently doing nothing', async ({ page }) => {
      await page.goto(SCRATCH_BOOK);
      await page.getByTestId('review-widget-label').click();
      await expect(page.locator('#review_modal')).toBeVisible();
      await page.getByTestId('review-star-button').nth(2).click();
      await page.getByRole('button', { name: 'Save' }).click();
      await expect(page.locator('#review_modal')).not.toBeVisible();

      await page.goto('/my/reviews');
      const row = page.locator('li', { has: page.locator(`a[href="${SCRATCH_BOOK}"]`) }).first();
      await expect(row).toBeVisible();

      // Intercept rather than actually spending the rate limit: 21 real writes
      // would be slow and would leave this account's budget exhausted for any
      // spec that runs next.
      await page.route(/\/reviews\/\d+$/, (route) =>
        route.fulfill({
          status: 429,
          contentType: 'text/vnd.turbo-stream.html',
          body: ''
        })
      );

      page.once('dialog', (d) => d.accept());
      await row.getByTestId('delete-review').click();

      await expect(page.locator('#toast-region')).toContainText('Wait a minute');
      // ...and the review is still there, which is the honest outcome to report.
      await expect(page.locator(`a[href="${SCRATCH_BOOK}"]`)).toHaveCount(2);

      await page.unroute(/\/reviews\/\d+$/);
    });
  });
});
