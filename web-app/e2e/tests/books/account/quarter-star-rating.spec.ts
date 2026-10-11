import { test, expect } from '@playwright/test';
import { rateStars } from '../../../helpers/star-rating';

// A book with no migrated reviews, so this spec never disturbs real data.
const BOOK = '/book/headlong-hall';

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

test.describe('Quarter-star ratings', () => {
  test.afterEach(async ({ page }) => {
    await page.goto(BOOK);
    await removeExistingReview(page);
  });

  test('hovering previews quarter steps; leaving restores the committed value', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();

    const star = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]').nth(2);
    const box = (await star.boundingBox())!;
    const readout = page.getByTestId('review-rating-readout');
    for (const [quarter, text] of [[1, '2.25'], [2, '2.5'], [3, '2.75'], [4, '3']] as const) {
      await page.mouse.move(box.x + (box.width * (quarter - 0.5)) / 4, box.y + box.height / 2);
      await expect(readout).toHaveText(text);
    }

    await page.mouse.move(5, 5);
    await expect(readout).toHaveText('Not rated');

    await rateStars(page, 3.75);
    await page.mouse.move(5, 5);
    await expect(readout).toHaveText('3.75');
  });

  test('arrow keys step by a quarter', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    await expect(page.locator('#review_modal')).toBeVisible();
    const slider = page.getByTestId('review-star-input');
    await slider.focus();
    await page.keyboard.press('End');
    await page.keyboard.press('ArrowLeft');
    await expect(slider).toHaveAttribute('aria-valuetext', '4.75 stars');
    await page.keyboard.press('PageDown');
    await expect(slider).toHaveAttribute('aria-valuetext', '3.75 stars');
  });

  test('a saved 3.75 shows exactly after saving, after reload, and when reopened', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').click();
    await rateStars(page, 3.75);
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(page.locator('#review_modal')).not.toBeVisible();

    const fourth = page.getByTestId('review-widget-stars').getByTestId('star-fill').nth(3);
    await expect(fourth).toHaveAttribute('style', /width: 75(\.0)?%/); // server-rendered Turbo Stream path

    await page.reload();
    await expect(fourth).toHaveAttribute('style', /width: 75(\.0)?%/); // JS hydration path
    await expect(page.getByTestId('review-widget-stars').getByRole('img')).toHaveAttribute('aria-label', 'Your rating: 3.75 out of 5 stars');

    await page.getByTestId('review-widget-label').click();
    await expect(page.getByTestId('review-rating-readout')).toHaveText('3.75');
  });
});

test.describe('Quarter-star ratings on a touch screen', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test.afterEach(async ({ page }) => {
    await page.goto(BOOK);
    await removeExistingReview(page);
  });

  test('a tap sets a value and a drag adjusts it', async ({ page }) => {
    await page.goto(BOOK);
    await page.getByTestId('review-widget-label').tap();
    await expect(page.locator('#review_modal')).toBeVisible();

    const stars = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]');
    const second = (await stars.nth(1).boundingBox())!;
    await stars.nth(1).tap({ position: { x: second.width * 0.375, y: second.height / 2 } });
    await expect(page.getByTestId('review-rating-readout')).toHaveText('1.5');

    // Drag: dispatch touch-type pointer events along the row. These synthetic events
    // exercise the controller's logic, not the browser's touch-pan-y/pointercancel handling.
    const slider = page.getByTestId('review-star-input');
    const last = (await stars.nth(3).boundingBox())!;
    const y = second.y + second.height / 2;
    await slider.dispatchEvent('pointerdown', { pointerType: 'touch', pointerId: 7, clientX: second.x + 2, clientY: y, button: 0 });
    await slider.dispatchEvent('pointermove', { pointerType: 'touch', pointerId: 7, clientX: last.x + last.width * 0.9, clientY: y });
    await slider.dispatchEvent('pointerup', { pointerType: 'touch', pointerId: 7, clientX: last.x + last.width * 0.9, clientY: y });
    await expect(page.getByTestId('review-rating-readout')).toHaveText('4');
  });
});
