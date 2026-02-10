import { type Page, type Locator } from '@playwright/test';

export class LoginPage {
  readonly page: Page;
  readonly loginButton: Locator;
  readonly modal: Locator;
  readonly modalTitle: Locator;
  readonly emailInput: Locator;
  readonly continueButton: Locator;
  readonly passwordInput: Locator;
  readonly signInButton: Locator;
  readonly closeButton: Locator;
  readonly googleSignInButton: Locator;

  constructor(page: Page) {
    this.page = page;
    this.loginButton = page.locator('#navbar_login_button');
    this.modal = page.locator('#login_modal');
    this.modalTitle = this.modal.getByRole('heading', { name: 'Sign In' });
    this.emailInput = this.modal.getByPlaceholder('Email address').first();
    this.continueButton = this.modal.getByRole('button', { name: 'Continue' });
    this.passwordInput = this.modal.getByPlaceholder('Password');
    this.signInButton = this.modal.getByRole('button', { name: 'Sign In' });
    this.closeButton = this.modal.getByRole('button', { name: 'Close' });
    this.googleSignInButton = this.modal.getByRole('button', { name: 'Sign in with Google' });
  }

  async goto() {
    await this.page.goto('/');
  }

  async openModal() {
    await this.loginButton.click();
  }

  async login(email: string, password: string) {
    await this.openModal();
    await this.emailInput.fill(email);
    await this.continueButton.click();
    await this.passwordInput.fill(password);
    await this.signInButton.click();
  }
}
