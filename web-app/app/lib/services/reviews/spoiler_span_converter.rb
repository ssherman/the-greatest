module Services
  module Reviews
    # One-shot conversion of the spoiler spans BodySanitizer.call used to generate on
    # write into the ||marker|| syntax it now stores. Used by the migration that runs
    # before the render change serves traffic.
    #
    # Parser-based, like everything else that touches this markup: a span's inner text
    # is put back as literal text, so nothing a reader typed can become markup.
    class SpoilerSpanConverter
      SPOILER_CLASS = BodySanitizer::SPOILER_CLASS

      def self.call(html)
        return nil if html.nil?

        fragment = Nokogiri::HTML5.fragment(html.to_s)
        spans = fragment.css("span.#{SPOILER_CLASS}").to_a
        return html.to_s if spans.empty?

        spans.each { |node| node.replace(Nokogiri::XML::Text.new("||#{node.text}||", fragment.document)) }
        fragment.to_html
      end
    end
  end
end
