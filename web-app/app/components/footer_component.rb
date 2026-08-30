# frozen_string_literal: true

# The site footer, shared by the books, music and games layouts.
#
# One component rather than three inline footers because most of what it holds
# is identical everywhere -- news, support, contact, the two policy pages and
# the copyright line -- and the parts that differ are a short list of browse
# links per site. Before this, music and games had a footer holding nothing but
# a copyright notice, and that notice was hardcoded to the wrong year.
#
# The domain is passed in rather than read from Current.domain here, following
# MailBranding: a class that reaches for Current renders one site's links on
# another the moment it is used somewhere Current is not set.
class FooterComponent < ViewComponent::Base
  # Books uses base-300 to match its own navbar -- its theme is a deliberate
  # brightness ladder. Music and games use base-200, which is what their
  # existing footers and navbars use.
  BACKGROUNDS = {
    books: "bg-base-300",
    music: "bg-base-200",
    games: "bg-base-200"
  }.freeze

  # Books accounts, so they appear only in the books footer. Music and games
  # have no accounts of their own yet; pointing their visitors at a books
  # account would be worse than showing nothing.
  SOCIAL_LINKS = [
    {name: "X (Twitter)", url: "https://twitter.com/thegreatestbks", icon: :x},
    {name: "Discord", url: "https://discord.gg/8JE9fpMtZp", icon: :discord},
    {name: "Facebook", url: "https://www.facebook.com/profile.php?id=61555129978566", icon: :facebook},
    {name: "Instagram", url: "https://www.instagram.com/thegreatestbooksever/", icon: :instagram}
  ].freeze

  def initialize(domain:)
    @domain = domain.to_sym
  end

  attr_reader :domain

  # fetch, not [] -- a domain with no entry raises here rather than rendering a
  # footer with no links, which would look intentional.
  def background = BACKGROUNDS.fetch(domain)

  # Written as direct helper calls rather than a table of symbols so that
  # grepping for a route helper finds this file.
  def browse_links
    case domain
    when :books
      [["Authors", helpers.books_authors_path],
        ["Genres", helpers.books_genres_path],
        ["Origins", helpers.books_countries_path],
        ["Lists", helpers.books_lists_path]]
    when :music
      [["Albums", helpers.albums_path],
        ["Songs", helpers.songs_path],
        ["Artists", helpers.artists_path],
        ["Lists", helpers.music_lists_path]]
    when :games
      [["Games", helpers.games_root_path],
        ["Lists", helpers.games_lists_path]]
    else
      raise KeyError, "no browse links for domain #{domain.inspect}"
    end
  end

  def site_links
    links = [["News", helpers.news_path]]
    links << ["Ranking Details", rankings_path] if rankings_path
    links << ["Support", helpers.membership_path]
    links << ["Contact", SiteContact::MAILTO]
    links
  end

  def legal_links
    [["Privacy Policy", helpers.privacy_policy_path],
      ["Deletion Policy", helpers.deletion_policy_path]]
  end

  def social_links = (domain == :books) ? SOCIAL_LINKS : []

  # Brand marks, inlined. The vendored rails_icons set is lucide, which has no
  # brand logos, and the legacy site's Bootstrap Icons font is not loaded here.
  # All four are 24x24 fill paths so one <svg> wrapper serves them.
  SOCIAL_ICON_PATHS = {
    x: "M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231 5.45-6.231Zm-1.161 17.52h1.833L7.084 4.126H5.117L17.083 19.77Z",
    discord: "M20.317 4.3698a19.7913 19.7913 0 0 0-4.8851-1.5152.0741.0741 0 0 0-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 0 0-.0785-.037 19.7363 19.7363 0 0 0-4.8852 1.515.0699.0699 0 0 0-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 0 0 .0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 0 0 .0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 0 0-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 0 1-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 0 1 .0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 0 1 .0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 0 1-.0066.1276 12.2986 12.2986 0 0 1-1.873.8914.0766.0766 0 0 0-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 0 0 .0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 0 0 .0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 0 0-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z",
    facebook: "M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073Z",
    instagram: "M12 2.163c3.204 0 3.584.012 4.85.07 3.252.148 4.771 1.691 4.919 4.919.058 1.265.069 1.645.069 4.849 0 3.205-.012 3.584-.069 4.849-.149 3.225-1.664 4.771-4.919 4.919-1.266.058-1.644.07-4.85.07-3.204 0-3.584-.012-4.849-.07-3.26-.149-4.771-1.699-4.919-4.92-.058-1.265-.07-1.644-.07-4.849 0-3.204.013-3.583.07-4.849.149-3.227 1.664-4.771 4.919-4.919 1.266-.057 1.645-.069 4.849-.069ZM12 0C8.741 0 8.333.014 7.053.072 2.695.272.273 2.69.073 7.052.014 8.333 0 8.741 0 12c0 3.259.014 3.668.072 4.948.2 4.358 2.618 6.78 6.98 6.98C8.333 23.986 8.741 24 12 24c3.259 0 3.668-.014 4.948-.072 4.354-.2 6.782-2.618 6.979-6.98.059-1.28.073-1.689.073-4.948 0-3.259-.014-3.667-.072-4.947-.196-4.354-2.617-6.78-6.979-6.98C15.668.014 15.259 0 12 0Zm0 5.838a6.162 6.162 0 1 0 0 12.324 6.162 6.162 0 0 0 0-12.324ZM12 16a4 4 0 1 1 0-8 4 4 0 0 1 0 8Zm6.406-11.845a1.44 1.44 0 1 0 0 2.881 1.44 1.44 0 0 0 0-2.881Z"
  }.freeze

  def social_icon_path(key) = SOCIAL_ICON_PATHS.fetch(key)

  private

  def rankings_path
    case domain
    when :books then helpers.books_rankings_path
    when :music then helpers.music_rankings_path
    when :games then helpers.games_rankings_path
    end
  end
end
