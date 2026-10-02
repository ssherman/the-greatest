# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t the_greatest .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name the_greatest the_greatest

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libwebp-dev postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems and node modules
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev node-gyp pkg-config python-is-python3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install JavaScript dependencies. node-build comes from a release tag whose
# tarball checksum is pinned here; if GitHub ever regenerates the archive the
# build fails loudly, and the fix is to re-verify and update the checksum.
ARG NODE_VERSION=22.20.0
ARG YARN_VERSION=1.22.22
ARG NODE_BUILD_VERSION=5.4.56
ARG NODE_BUILD_SHA256=23ee5f1fb900437ac14d3f7012de861dc5ba86ccddb45526315a70dea5933f72
ENV PATH=/usr/local/node/bin:$PATH
RUN curl -fsSL -o /tmp/node-build.tar.gz "https://github.com/nodenv/node-build/archive/refs/tags/v${NODE_BUILD_VERSION}.tar.gz" && \
    echo "${NODE_BUILD_SHA256}  /tmp/node-build.tar.gz" | sha256sum -c - && \
    tar xzf /tmp/node-build.tar.gz -C /tmp/ && \
    /tmp/node-build-${NODE_BUILD_VERSION}/bin/node-build "${NODE_VERSION}" /usr/local/node && \
    npm install -g yarn@$YARN_VERSION && \
    rm -rf /tmp/node-build.tar.gz /tmp/node-build-${NODE_BUILD_VERSION}

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Install node modules
COPY package.json yarn.lock ./
# --frozen-lockfile, not --immutable: Yarn Classic ignores --immutable and
# would rewrite a drifted yarn.lock instead of failing.
RUN yarn install --frozen-lockfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


RUN rm -rf node_modules


# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start Rails server on port 3000, bound to all interfaces for nginx proxy
EXPOSE 3000
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]
