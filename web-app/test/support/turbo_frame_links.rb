# frozen_string_literal: true

# Finds the links on a rendered page whose Turbo navigation is scoped to a
# <turbo-frame>. Turbo navigates the frame a link sits in, not the page, so a
# link pointing at a document without that frame renders "Content missing"
# instead of navigating.
#
# Deliberately pure and HTTP-free: assert_no_frame_trapped_links (test_helper)
# supplies the requests. Once a page is fixed this returns nothing for it, so
# the unit tests here are the only thing proving the resolution logic works.
module TurboFrameLinks
  Candidate = Data.define(:href, :frame_id)

  UNFOLLOWABLE_SCHEMES = %w[mailto tel javascript].freeze

  # Turbo resolves a click's target frame in this order:
  #   the anchor's data-turbo-frame, the frame's target, the frame's own id.
  # "_top" means the whole page, so those anchors are safe and omitted.
  # data-turbo="false" is skipped too, but real Turbo ignores that attribute
  # once an explicit frame id resolves — so that combination (not used in this
  # app) would be a false negative here.
  def self.trapped_candidates(html, host: nil)
    anchors = Nokogiri::HTML5(html).css("a[href]")

    candidates = anchors.filter_map do |anchor|
      frame = anchor.ancestors("turbo-frame").first
      next if frame.nil?
      next if anchor["data-turbo"] == "false"

      target = anchor["data-turbo-frame"] || frame["target"] || frame["id"]
      next if target == "_top"

      href = anchor["href"].to_s.strip
      next unless followable?(href, host)

      Candidate.new(href: href, frame_id: target)
    end

    candidates.uniq
  end

  # Only same-document GET navigations can be replayed by the assertion.
  def self.followable?(href, host)
    return false if href.empty? || href.start_with?("#")
    return false if UNFOLLOWABLE_SCHEMES.any? { |scheme| href.downcase.start_with?("#{scheme}:") }
    return true unless href.match?(%r{\A(https?:)?//})
    return false if host.nil?

    URI.parse(href).host == host
  rescue URI::InvalidURIError
    false
  end
  private_class_method :followable?
end
