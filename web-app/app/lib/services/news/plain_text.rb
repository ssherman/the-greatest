module Services
  module News
    # HTML to plain text, inserting a separator at every BLOCK boundary.
    #
    # Do NOT replace this with `Nokogiri::HTML5.fragment(html).text`. That
    # concatenates across blocks -- "<p>one</p><p>two</p>" becomes "onetwo" and
    # "one<br>two" becomes "onetwo" -- which is how a <br> silently vanishes and
    # two sentences fuse into one. It also makes the migration's round-trip
    # check compare a legacy <div>-per-paragraph body against a rendered
    # <p>-per-paragraph body and report a false mismatch on every multi-block
    # post; measured on the real corpus, that was 2 of 31.
    #
    # Used by NewsPost#excerpt and by the migration's round-trip verification,
    # which must normalise both sides identically.
    class PlainText
      BLOCK_TAGS = %w[
        p div br hr pre blockquote
        h1 h2 h3 h4 h5 h6
        ul ol li table tr th td
      ].freeze

      def self.call(html)
        return "" if html.blank?

        fragment = Nokogiri::HTML5.fragment(html.to_s)
        fragment.css(BLOCK_TAGS.join(",")).each do |node|
          node.add_previous_sibling(Nokogiri::XML::Text.new(" ", fragment.document))
        end

        fragment.text.gsub(/[[:space:]]+/, " ").strip
      end
    end
  end
end
