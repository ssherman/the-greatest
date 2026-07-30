import { type Locator, type Page } from '@playwright/test';
import { test, expect } from '../../../fixtures/auth';

// The panel renders inside a lazy-loaded turbo frame (loading: :lazy), so it only
// fetches once it scrolls into the viewport. Scroll it into view and wait for the
// loading spinner to be replaced by the real content before interacting with it,
// mirroring the convention used for the album lists-items panel.
async function openDescriptionsPanel(page: Page): Promise<Locator> {
  const frame = page.locator('turbo-frame#descriptions_list');
  await frame.scrollIntoViewIfNeeded();
  await expect(frame.locator('.loading-spinner')).toBeHidden({ timeout: 10000 });
  await expect(page.getByRole('heading', { name: 'Descriptions', exact: true })).toBeVisible();
  return frame;
}

test.describe('Admin Descriptions Panel', () => {
  test('adds a description, moves the preferred badge, and deletes it', async ({ page, albumsPage }) => {
    await albumsPage.goto();
    await albumsPage.clickFirstAlbum();

    const frame = await openDescriptionsPanel(page);

    const runId = Date.now();
    const contentA = `E2E description ${runId} Alpha`;
    const contentB = `E2E description ${runId} Beta`;
    const sourceNameA = `E2E Source ${runId} Alpha`;
    const sourceNameB = `E2E Source ${runId} Beta`;

    const addDialog = page.locator('dialog#add_description_modal');
    const cardFor = (content: string) =>
      frame.locator('[data-testid^="description-card-"]').filter({ hasText: content });

    async function addDescription(content: string, sourceName: string) {
      await frame.getByRole('button', { name: '+ Add Description', exact: true }).click();
      await expect(addDialog).toBeVisible();

      // Landmine (discovered while writing this test, not just theorized): the shared
      // _form_fields partial is rendered once per open dialog (this add form, plus one
      // edit form per existing description card), and Rails' default field ids
      // ("description_content", "description_source_name", ...) are identical across
      // every rendering. That means the page can legitimately have more than one
      // element sharing the same id, so label[for=...]/getByLabel resolution is not
      // reliable here - it can silently resolve to a field inside a different,
      // currently-closed dialog instead of this open one. data-testid is the only
      // way to reliably scope to the field inside *this* dialog.
      await addDialog.getByTestId('description-content-input').fill(content);
      await addDialog.getByTestId('description-source-select').selectOption('other');
      await addDialog.getByTestId('description-source-name-input').fill(sourceName);
      await addDialog.getByRole('button', { name: 'Add Description', exact: true }).click();

      // Landmine (flagged in review): this add-modal lives INSIDE the descriptions_list
      // turbo frame, unlike the images panel it was modelled on. On a successful submit,
      // the turbo stream replaces the whole frame while the modal-form Stimulus
      // controller's turbo:submit-end handler is closing the dialog by id, so
      // getElementById may resolve the freshly-rendered (already-closed) dialog rather
      // than the detached open one. Assert the dialog is actually gone from the screen
      // rather than assuming it worked - if this fails, that is a real bug, not
      // something to paper over with a wait or a forced close.
      await expect(addDialog).toBeHidden();
    }

    // --- Add the first description; confirm it appears with no Preferred badge yet ---
    await addDescription(contentA, sourceNameA);

    const cardA = cardFor(contentA);
    await expect(cardA).toHaveCount(1);
    await expect(cardA.getByText('Preferred', { exact: true })).toHaveCount(0);

    // --- Add a second description so we can prove the Preferred badge moves between
    // records rather than just appearing once ---
    await addDescription(contentB, sourceNameB);

    const cardB = cardFor(contentB);
    await expect(cardB).toHaveCount(1);
    await expect(cardB.getByText('Preferred', { exact: true })).toHaveCount(0);

    // --- Mark A preferred ---
    await cardA.getByRole('button', { name: 'Make preferred' }).click();
    await expect(cardA.getByText('Preferred', { exact: true })).toBeVisible();
    await expect(cardB.getByText('Preferred', { exact: true })).toHaveCount(0);

    // --- Mark B preferred; the badge must move off A and onto B ---
    await cardB.getByRole('button', { name: 'Make preferred' }).click();
    await expect(cardB.getByText('Preferred', { exact: true })).toBeVisible();
    await expect(cardA.getByText('Preferred', { exact: true })).toHaveCount(0);
    await expect(cardA.getByRole('button', { name: 'Make preferred' })).toBeVisible();

    // --- Clean up: delete both disposable descriptions so the album is left as found ---
    page.once('dialog', (confirmDialog) => confirmDialog.accept());
    await cardB.getByRole('button', { name: 'Delete' }).click();
    await expect(cardB).toHaveCount(0);

    page.once('dialog', (confirmDialog) => confirmDialog.accept());
    await cardA.getByRole('button', { name: 'Delete' }).click();
    await expect(cardA).toHaveCount(0);
  });
});
