# frozen_string_literal: true

require Rails.root.join("config/host_allowlist").to_s

# Production only. Not in production.rb: environment files run before
# config/initializers, and config.domains is set by domain_config.rb, which
# sorts before this file. development.rb keeps its own list; test sets none.
if Rails.env.production?
  Rails.application.configure do
    config.hosts.concat(HostAllowlist.hosts(config.domains))
    config.host_authorization = HostAllowlist.authorization
  end
end
