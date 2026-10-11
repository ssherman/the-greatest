import { expect, Page } from '@playwright/test';

// Clicks the review dialog's star input at the x position that yields `value`
// (a multiple of 0.25). Aims at the middle of the target quarter of the star,
// so rounding up lands exactly on the value.
export async function rateStars(page: Page, value: number) {
  const index = Math.ceil(value) - 1;
  const quarter = Math.round((value - index) * 4); // 1..4
  const star = page.getByTestId('review-star-input').locator('[data-reviews--star-input-target="star"]').nth(index);
  // The dialog opens asynchronously, so wait for the star before measuring it.
  await expect(star).toBeVisible();
  const box = await star.boundingBox();
  if (!box) throw new Error('star input is not visible');
  await star.click({ position: { x: (box.width * (quarter - 0.5)) / 4, y: box.height / 2 } });
  await expect(page.getByTestId('review-rating-readout')).toHaveText(String(value));
}
