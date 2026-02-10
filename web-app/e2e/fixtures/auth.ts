import { test as base } from '@playwright/test';
import { HomePage } from '../pages/music/home-page';
import { LoginPage } from '../pages/music/admin/login-page';
import { DashboardPage } from '../pages/music/admin/dashboard-page';
import { ArtistsPage } from '../pages/music/admin/artists-page';
import { AlbumsPage } from '../pages/music/admin/albums-page';
import { SongsPage } from '../pages/music/admin/songs-page';

type Fixtures = {
  homePage: HomePage;
  loginPage: LoginPage;
  dashboardPage: DashboardPage;
  artistsPage: ArtistsPage;
  albumsPage: AlbumsPage;
  songsPage: SongsPage;
};

export const test = base.extend<Fixtures>({
  homePage: async ({ page }, use) => {
    await use(new HomePage(page));
  },
  loginPage: async ({ page }, use) => {
    await use(new LoginPage(page));
  },
  dashboardPage: async ({ page }, use) => {
    await use(new DashboardPage(page));
  },
  artistsPage: async ({ page }, use) => {
    await use(new ArtistsPage(page));
  },
  albumsPage: async ({ page }, use) => {
    await use(new AlbumsPage(page));
  },
  songsPage: async ({ page }, use) => {
    await use(new SongsPage(page));
  },
});

export { expect } from '@playwright/test';
