import { test, expect, Page } from '@playwright/test';

// The widget is shared by every domain layout, so each hostname gets the same
// checks. storageState is cleared explicitly: the books project starts
// anonymous already, but the override makes that a property of the test rather
// than of the project config.
const DOMAINS = [
  { name: 'books', baseURL: 'https://dev-new.thegreatestbooks.org' },
  { name: 'music', baseURL: 'https://dev.thegreatestmusic.org' },
  { name: 'games', baseURL: 'https://dev.thegreatest.games' },
];

// Mirrors the enabled entries in web-app/config/auth_providers.json.
// test/components/.../widget_component_test.rb pins the rendered markup to that
// file; this pins what a real browser gets.
const ENABLED = [
  { id: 'google', label: 'Google', firebaseId: 'google.com' },
  { id: 'twitter', label: 'X', firebaseId: 'twitter.com' },
  { id: 'facebook', label: 'Facebook', firebaseId: 'facebook.com' },
];

const DISABLED = ['apple'];

async function openLoginModal(page: Page) {
  await page.goto('/');
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page.locator('#login_modal')).toBeVisible();
}

for (const domain of DOMAINS) {
  test.describe(`OAuth provider buttons on ${domain.name}`, () => {
    test.use({ baseURL: domain.baseURL, storageState: { cookies: [], origins: [] } });

    test('renders exactly the enabled providers', async ({ page }) => {
      await openLoginModal(page);
      const modal = page.locator('#login_modal');

      for (const provider of ENABLED) {
        const button = modal.locator(`button[data-authentication-provider-param="${provider.id}"]`);
        await expect(button).toBeVisible();
        // Exact, not substring: Capybara-style containment would pass on
        // "Sign in with Xylophone".
        await expect(button).toHaveText(`Sign in with ${provider.label}`);
      }

      for (const id of DISABLED) {
        await expect(
          modal.locator(`button[data-authentication-provider-param="${id}"]`)
        ).toHaveCount(0);
      }
    });

    // Every enabled provider gets this, not just one: the provider id travels
    // from the JSON through a Stimulus action param into the Firebase factory
    // map, and a provider missing from that map fails only on click. Checking
    // one provider leaves the others unproven.
    for (const provider of ENABLED) {
      test(`clicking ${provider.label} starts the Firebase redirect with the right providerId`, async ({
        page,
      }) => {
        await openLoginModal(page);

        await page
          .locator(`#login_modal button[data-authentication-provider-param="${provider.id}"]`)
          .click();

        // signInWithRedirect goes to the Firebase auth handler on THIS host
        // (nginx and Caddy proxy /__/auth* to the-greatest-books.firebaseapp.com)
        // before it ever reaches the provider. Waiting on that URL keeps the
        // test off the provider's bot detection while still proving the whole
        // client path.
        const escaped = provider.firebaseId.replace(/\./g, '\\.');
        await page.waitForURL(
          new RegExp(`/__/auth/handler\\?.*providerId=${escaped}`),
          { timeout: 20000 }
        );

        expect(page.url()).toContain(`providerId=${provider.firebaseId}`);
      });
    }

    test('an unknown provider id does not silently do nothing', async ({ page }) => {
      await openLoginModal(page);

      const errors: string[] = [];
      page.on('console', (msg) => {
        if (msg.type() === 'error') errors.push(msg.text());
      });

      // Rewrite a real button's param to an id the registry does not carry,
      // which is what stale Turbo-cached markup would look like after a
      // provider is removed from the config.
      await page.locator('#login_modal button[data-authentication-provider-param="google"]')
        .evaluate((el) => el.setAttribute('data-authentication-provider-param', 'nope'));

      await page.locator('#login_modal button[data-authentication-provider-param="nope"]').click();

      await expect(
        page.locator('#login_modal [data-authentication-target="errorMessage"]')
      ).toBeVisible();
      expect(errors.some((e) => e.includes('Unknown auth provider'))).toBe(true);
    });
  });
}
