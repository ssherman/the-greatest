# Resolves a domain key into the identity an email should wear: which site it
# claims to be from, what it looks like, and which host its links point at.
#
# Deliberately top-level and not nested under another module. A constant looked
# up from inside a nested module resolves against that module first, which has
# produced confusing NameErrors in this codebase more than once.
#
# Callers pass the domain EXPLICITLY. Mailers run inside Sidekiq where
# Current.domain is nil, so a mailer that reads Current sends books-branded mail
# to music subscribers, silently. memberships.origin_domain exists to be passed
# here -- and is nil for every membership predating checkout, which is why the
# fallback below is a supported case rather than a defensive afterthought.
class MailBranding
  class MissingFromAddress < StandardError; end

  DEFAULT_DOMAIN = :books

  # Hex, because email clients cannot parse oklch(). books matches its theme's
  # --color-primary exactly; music uses daisyUI's stock light primary, which is
  # the theme it ships. Decorative only -- nothing in an email depends on a
  # reader telling two of these apart.
  #
  # This hash is also the allowlist: a domain absent from it has no email
  # identity and falls back to DEFAULT_DOMAIN. Site names deliberately are NOT
  # here -- they already live in config.domain_settings and must not be
  # duplicated, or the two copies will drift.
  BRAND_COLORS = {
    books: "#194F81",
    music: "#422AD5",
    games: "#006757"
  }.freeze

  attr_reader :key

  def self.for(domain)
    key = domain.presence&.to_sym
    new(BRAND_COLORS.key?(key) ? key : DEFAULT_DOMAIN)
  end

  def initialize(key)
    @key = key
  end

  def site_name
    Rails.application.config.domain_settings.fetch(key).fetch(:name)
  end

  def brand_color
    BRAND_COLORS.fetch(key)
  end

  def from
    address = ENV["MAIL_FROM_ADDRESS"]
    raise MissingFromAddress, "MAIL_FROM_ADDRESS is not set; refusing to send from a malformed address" if address.blank?

    "#{site_name} <#{address}>"
  end

  def url_options
    options = {host: host, protocol: Rails.env.production? ? "https" : "http"}
    options[:port] = 3000 unless Rails.env.production?
    options
  end

  private

  # config.domains values come from ENV and may hold a comma-separated list.
  # Same rule as MembershipController#canonical_host.
  def host
    Rails.application.config.domains[key].to_s.split(",").first
  end
end
