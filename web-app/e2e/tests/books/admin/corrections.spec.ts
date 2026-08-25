import { test, expect } from '@playwright/test';

// nightmare-abbey is this repo's designated E2E scratch book -- see
// lib/tasks/e2e.rake and e2e/tests/books/admin/reviews.spec.ts, which already
// write and delete data against it -- so the apply case, which permanently
// mutates a real book field, lands on it rather than on a canonical work.
// war-and-peace is any ordinary book: rejecting a correction never touches
// the corrected record, so there is nothing to be careful about there.
// Both have no subtitle in the migrated corpus (verified with
// `bin/rails runner` before writing this file), so the marker text below is
// unambiguously new content, not a coincidental match.
// UNVERIFIED NOTE (not run: port 3000 belonged to another worktree when the
// final review fixes landed). Nothing in this file changed, and nothing in it
// needed to: the correction URLs below never carried an /rc/<id> prefix, and the
// prefix has since been removed from the routes entirely, so these paths are
// still the only ones that resolve. The review form's ARRAY fields
// (alternate_titles) now render one input per element instead of one
// comma-joined input -- no test here touches an array field, and the string
// field this spec does drive (#accepted_subtitle) is unchanged. That change is
// covered by Admin::CorrectionsControllerTest, not here.
const APPLY_BOOK = '/book/nightmare-abbey';
const REJECT_BOOK = '/book/war-and-peace';
const SUBTITLE_MARKER = 'A Gothic Satire [e2e-corrections-spec]';
const NOTES_MARKER = 'E2E corrections spec: reject-with-reason case';
const REJECT_REASON = 'Not a real issue -- E2E spec';

test.describe('Admin corrections', () => {
  test('a submitted correction appears in the pending queue and can be applied', async ({ page }) => {
    // Drive the real pipeline end to end -- Submission service, honeypot
    // check, admin queue, Applier -- by submitting from the public form
    // rather than seeding a Correction row directly.
    await page.goto(`${APPLY_BOOK}/suggest-correction`);
    const subtitle = page.locator('#correction_fields_subtitle');
    await subtitle.click();
    await subtitle.fill(SUBTITLE_MARKER);
    await page.getByTestId('correction-submit').click();

    // #create redirects to a dedicated thanks page on success, not back to
    // the book -- the book page is edge-cached with the session skipped, so
    // a flash set on a redirect there would never be read (Toast::RegionComponent
    // only ever fires from an explicit `toast:show` dispatch in a handful of
    // Stimulus controllers, none of which are wired to this endpoint). The
    // thanks page states the confirmation as static content instead.
    //
    // This also keeps the browser's disk cache out of the later `page.goto`
    // back to APPLY_BOOK below: if #create still redirected to the book page
    // itself, that GET -- happening BEFORE the correction is applied -- would
    // be the only navigation to APPLY_BOOK before the strongest-proof
    // assertion revisits it, and Chromium could serve that stale pre-apply
    // response from cache instead of re-fetching, turning a real pass into a
    // false failure.
    await expect(page).toHaveURL(new RegExp(`${APPLY_BOOK}/suggest-correction/thanks$`));

    await page.goto('/admin/corrections');
    await expect(page.getByTestId('status-tab-pending')).toBeVisible();

    // Correction.recent orders pending corrections created_at desc, id desc,
    // so the one just submitted -- always the highest id in the table -- is
    // first regardless of what earlier runs of this spec left behind.
    await page.getByTestId('correction-row').first().getByRole('link').click();
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Correction #/);

    // Proves Submission persisted exactly what was typed, not just that a
    // correction of some shape exists -- the review form's proposed-value
    // input is seeded from field.new_value.
    const fieldRow = page.locator('[data-testid="correction-field-row"][data-field="subtitle"]');
    await expect(fieldRow).toBeVisible();
    await expect(page.locator('#accepted_subtitle')).toHaveValue(SUBTITLE_MARKER);

    await page.getByTestId('apply-correction').click();
    await expect(page.getByText('Correction applied.')).toBeVisible();

    // The correction is no longer pending, so the review/reject/resolve
    // controls -- each rendered only `if @correction.pending?` -- are gone.
    // That is proof the status actually flipped, not just that a flash
    // string appeared.
    await expect(page.getByTestId('apply-correction')).toHaveCount(0);
    await expect(page.getByTestId('reject-correction')).toHaveCount(0);
    await expect(page.getByTestId('resolve-correction')).toHaveCount(0);

    // The strongest proof of all: Applier wrote the field onto the real
    // record, and the public page reads it live. If apply were a no-op, this
    // text would not exist anywhere -- nightmare-abbey has no subtitle
    // otherwise. This is also the FIRST time this test visits APPLY_BOOK
    // itself (the earlier submission redirected to the thanks page, not
    // here), so there is no pre-apply disk-cached response it could be
    // served instead -- this goto is guaranteed to be a real fetch.
    await page.goto(APPLY_BOOK);
    await expect(page.getByText(SUBTITLE_MARKER)).toBeVisible();
  });

  test('a correction can be rejected with a reason and drops out of the pending queue', async ({ page }) => {
    await page.goto(`${REJECT_BOOK}/suggest-correction`);
    await page.locator('#correction_notes').fill(NOTES_MARKER);
    await page.getByTestId('correction-submit').click();
    await expect(page).toHaveURL(new RegExp(`${REJECT_BOOK}/suggest-correction/thanks$`));

    await page.goto('/admin/corrections');
    await page.getByTestId('correction-row').first().getByRole('link').click();

    // Confirms the notes actually round-tripped onto this exact correction
    // before rejecting it -- rejecting the wrong row, or a submission that
    // silently dropped the notes, would still let the assertions below
    // "pass" for the wrong reason.
    await expect(page.getByText(NOTES_MARKER)).toBeVisible();
    const correctionId = page.url().match(/\/corrections\/(\d+)$/)?.[1];
    expect(correctionId, 'expected the show page URL to end in /corrections/<id>').toBeTruthy();

    // No accessible label ties to this input (a placeholder, not a <label>),
    // so role/text/testid genuinely cannot target it -- getByPlaceholder is
    // the correct tool here, not a reason to add a data-testid.
    await page.getByPlaceholder('Reason (optional)').fill(REJECT_REASON);
    await page.getByTestId('reject-correction').click();

    // reject redirects to the index with no status param, i.e. the pending
    // tab, and this correction must no longer be in it.
    await expect(page).toHaveURL(/\/admin\/corrections$/);
    await expect(page.getByText('Correction rejected.')).toBeVisible();
    await expect(page.getByTestId('status-tab-pending')).toHaveClass(/tab-active/);
    await expect(page.locator(`[data-testid="correction-row"][data-correction-id="${correctionId}"]`)).toHaveCount(0);

    // It reappears under Rejected -- proof the reject action actually wrote
    // the status change to the database and the index's status filter reads
    // it back, not just that the controller returned a friendly string.
    await page.getByTestId('status-tab-rejected').click();
    const rejectedRow = page.locator(`[data-testid="correction-row"][data-correction-id="${correctionId}"]`);
    await expect(rejectedRow).toBeVisible();

    // And the show page reflects the same: review controls gone, the reason
    // that was typed persisted as resolution_notes.
    await rejectedRow.getByRole('link').click();
    await expect(page.getByTestId('reject-correction')).toHaveCount(0);
    await expect(page.getByTestId('resolve-correction')).toHaveCount(0);
    await expect(page.getByText(REJECT_REASON)).toBeVisible();
  });
});
