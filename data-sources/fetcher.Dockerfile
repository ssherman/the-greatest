# The page fetcher image (docs/superpowers/specs/2026-09-26-page-fetcher-service-design.md).
# Separate from the Open Library image (./Dockerfile) so that one never carries Firefox.
#
# bookworm, not the floating slim tag: the apt package names below are Debian 12's.
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY --from=ghcr.io/astral-sh/uv:0.11.17 /uv /uvx /bin/

# Xvfb, fonts, and Firefox's runtime libraries: Playwright's Debian 12 list for
# Firefox, plus libxt6, libpci3 and Mesa for the software GL that Camoufox's Xvfb
# display uses. fetcher.install_check fails the build if Firefox still lacks one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb xfonts-scalable fontconfig fonts-liberation fonts-noto-color-emoji fonts-dejavu-core \
      ca-certificates \
      libasound2 libatk1.0-0 libcairo-gobject2 libcairo2 libdbus-1-3 libdbus-glib-1-2 \
      libfontconfig1 libfreetype6 libgdk-pixbuf-2.0-0 libglib2.0-0 libgtk-3-0 libharfbuzz0b \
      libpango-1.0-0 libpangocairo-1.0-0 libx11-6 libx11-xcb1 libxcb-shm0 libxcb1 \
      libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxrandr2 \
      libxrender1 libxtst6 libxt6 libpci3 libgl1 libegl1 libgl1-mesa-dri \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Lockfile-only layer, as in the Open Library image: --locked fails the build on drift.
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --extra fetcher --no-install-project

COPY src/ ./src/
RUN uv sync --locked --no-dev --extra fetcher

ENV PATH="/app/.venv/bin:$PATH"

# Firefox and Xvfb run as this user, never root (spec §6).
RUN useradd --create-home --uid 10001 fetcher
USER fetcher

# One named browser build (spec §4). `camoufox fetch <version>` with an
# explicit version installs exactly that build and marks it active
# (multiversion.py's install_versioned calls set_active() then touches its
# install-completion flag). `camoufox set` followed by a bare `camoufox
# fetch` is NOT equivalent and must not be used: `set` never touches that
# flag, so the bare `fetch` that follows sees a non-empty, flag-less install
# dir, deletes it, and falls through to "newest stable in the channel" --
# silently discarding the pin the day a newer build ships. install_check
# verifies the install, because fetch exits 0 on failure. The browser lands
# in ~fetcher/.cache/camoufox.
ARG CAMOUFOX_BROWSER=official/stable/152.0.4-beta.31
ENV CAMOUFOX_BROWSER=${CAMOUFOX_BROWSER}
RUN camoufox fetch "$CAMOUFOX_BROWSER" \
 && python -m fetcher.install_check

EXPOSE 8081
CMD ["uvicorn", "--factory", "fetcher.api.main:factory", \
     "--host", "0.0.0.0", "--port", "8081"]
