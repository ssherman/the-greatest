import { test, expect } from '@playwright/test';

// A book with no migrated reviews, so this spec never disturbs real data.
const BOOK = '/book/nightmare-abbey';

async function removeExistingReview(page) {
  await page.getByTestId('review-widget-label').click();

  // widget_controller#open() is async (it may still be awaiting its /review_state
  // fetch), so the dialog does not necessarily exist the instant the click resolves.
  // Wait for it to actually be open -- an auto-retrying expect, not a one-shot
  // isVisible() -- before reading the Remove button's state. modal_controller's
  // _onOpen() decides removeTarget's hidden class before it calls showModal(), so by
  // the time the dialog is visible that decision is already settled. This also fails
  // loudly (throws) rather than silently doing nothing if the dialog never opens at
  // all, which matters here: a cleanup hook for irreplaceable dev data must not give
  // up quietly.
  await expect(page.locator('#review_modal')).toBeVisible();

  const remove = page.getByTestId('review-remove');
  if (await remove.isVisible()) {
    await remove.click();
    await expect(page.locator('#review_modal')).not.toBeVisible();
  } else {
    await page.locator('#review_modal').press('Escape');
    await expect(page.locator('#review_modal')).not.toBeVisible();
  }
}

test.describe('Writing a review', () => {
  test.afterEach(async ({ page }) => {
    await page.goto(BOOK);
    await removeExistingReview(page);
  });

  test('a signed-in reader can leave a rating with no text', async ({ page }) => {
    await page.goto(BOOK);

    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();

    await page.getByTestId('review-star-button').nth(3).click();
    await page.getByRole('button', { name: 'Save' }).click();

    await expect(page.locator('#review_modal')).not.toBeVisible();
    await expect(page.getByTestId('review-widget-label')).toHaveText('Edit your review');
    await expect(page.locator('#review_summary_line')).toContainText('1 rating');
  });

  test('a rating can be given a written review and edited', async ({ page }) => {
    await page.goto(BOOK);

    await page.getByTestId('review-widget-label').click();
    await page.getByTestId('review-star-button').nth(4).click();
    await page.locator('#review_modal textarea').fill('A strange little book.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    // ReviewsController#render_widget_and_summary streams #review_widget,
    // #review_summary_line AND the Ratings & Reviews card, so the written body
    // shows up live without a reload.
    await expect(page.getByTestId('review')).toContainText('A strange little book.');

    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal textarea')).toHaveValue('A strange little book.');
    await page.locator('#review_modal textarea').fill('Revised opinion.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await expect(page.getByTestId('review')).toContainText('Revised opinion.');
  });

  test('a review can be removed', async ({ page }) => {
    await page.goto(BOOK);

    await page.getByTestId('review-widget-label').click();
    await page.getByTestId('review-star-button').nth(2).click();
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.getByTestId('review-widget-label')).toHaveText('Edit your review');

    await page.getByTestId('review-widget-label').click();
    await page.getByTestId('review-remove').click();

    await expect(page.getByTestId('review-widget-label')).toHaveText('Rate this book');
    // The wrapper survives the update; the component inside it renders nothing.
    await expect(page.getByTestId('review-summary-line')).toHaveCount(0);
  });

  test('a spoiler survives being written, reloaded and edited', async ({ page }) => {
    await page.goto(BOOK);

    await page.getByTestId('review-widget-label').click();
    await page.getByTestId('review-star-button').nth(3).click();
    await page.locator('#review_modal textarea').fill('He ||dies|| at the end.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await expect(page.locator('.review-spoiler')).toHaveText('dies');

    // The author sees what they typed, not generated markup.
    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal textarea')).toHaveValue('He ||dies|| at the end.');

    // And the spoiler survives an edit -- the defect this whole change removes.
    await page.locator('#review_modal textarea').fill('He ||dies|| at the very end.');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    await expect(page.locator('.review-spoiler')).toHaveText('dies');
  });
});
