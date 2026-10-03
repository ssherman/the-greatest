# frozen_string_literal: true

# The hosts production admits (config.hosts) and the requests exempt from that
# check. Kept out of the initializer so test/config/host_allowlist_test.rb can
# run the real middleware with them: config.hosts is set only in production,
# so no integration test ever passes through it.
#
# Plain file, required by path: config/initializers cannot autoload reloadable
# constants from app/ or lib/.
module HostAllowlist
  # config.domains is the same source config/routes.rb constrains on, and each
  # value may be a comma-separated list (see DomainConstraint), so every host
  # the routes serve is admitted and nothing has to be kept in sync by hand.
  def self.hosts(domains)
    hosts = domains.values.flat_map { |value| value.split(",") }.uniq
    # An empty config.hosts switches the check off rather than refusing
    # everything, so fail at boot instead.
    raise ArgumentError, "config.domains yields no hosts" if hosts.empty?
    hosts
  end

  # /up is the container healthcheck (docker-compose.prod.yml), which curls
  # localhost:3000 directly rather than through nginx.
  def self.authorization
    {exclude: ->(request) { request.path == "/up" }}
  end
end
