import { test, expect } from '@playwright/test';

test.describe('Suggest a correction', () => {
  test('the book page links to the correction form', async ({ page }) => {
    await page.goto('/book/war-and-peace');

    await page.getByTestId('suggest-correction-link').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace\/suggest-correction$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Suggest a correction' })).toBeVisible();
  });

  test('the form is not indexable', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    const robots = page.locator('meta[name="robots"]');
    await expect(robots).toHaveAttribute('content', 'noindex, follow');
  });

  test('an anonymous visitor can submit notes', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    await page.getByRole('textbox').first().fill('The first published year looks wrong.');
    await page.getByTestId('correction-submit').click();

    // #create redirects to the dedicated thanks page, not back to the book --
    // the book page is edge-cached with the session skipped, so a flash set on
    // a redirect there is never read. The thanks page states the confirmation
    // as static content instead.
    await expect(page).toHaveURL(/\/book\/war-and-peace\/suggest-correction\/thanks$/);
    await expect(page.getByText(/we've got it/i)).toBeVisible();
  });

  test('an anonymous visitor can propose a field change', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    // click() and fill() trigger focus, which fires ensureToken() via the
    // form's focusin action -- but nothing here awaits the returned promise,
    // and no assertion inspects the applied token. Submission succeeds
    // either way (null_session accepts an anonymous write if the token
    // fetch hasn't landed yet), so this test gives no coverage of token
    // hydration itself -- only that a field change can be submitted.
    const yearInput = page.locator('#correction_fields_first_published_year');
    await yearInput.click();
    await yearInput.fill('1867');
    await page.getByTestId('correction-submit').click();

    await expect(page).toHaveURL(/\/book\/war-and-peace\/suggest-correction\/thanks$/);
    await expect(page.getByText(/we've got it/i)).toBeVisible();
  });

  // UNVERIFIED NOTE (not run: port 3000 belonged to another worktree when the
  // final review fixes landed). The name for a row added here now comes from the
  // list element's data-input-name attribute rather than a literal inside
  // form_controller.js -- the admin review form drives the same controller with a
  // different name (accepted[<field>][]). The attribute is set in
  // app/views/corrections/new.html.erb; if this test ever fails on the count
  // assertion, check that attribute first.
  test('an alternate title row can be added and removed', async ({ page }) => {
    await page.goto('/book/war-and-peace/suggest-correction');

    const list = page.locator('[data-shared--form-token-target="list"][data-field="alternate_titles"]');
    const before = await list.locator('input').count();

    await page.getByRole('button', { name: /^Add alternate title$/ }).click();
    await expect(list.locator('input')).toHaveCount(before + 1);

    await list.locator('button', { hasText: 'Remove' }).last().click();
    await expect(list.locator('input')).toHaveCount(before);
  });
});
