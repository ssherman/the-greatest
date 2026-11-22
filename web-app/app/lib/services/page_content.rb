# frozen_string_literal: true

module Services
  # Turns the HTML a fetched page came back as into what an agent reads: `simplified`
  # (structure kept, scripts, styling and attributes gone), `text`, or `html` (as returned).
  # Every format is capped; `length` is the uncapped length. The Wayback Machine's injected
  # toolbar is removed first, so it never reaches an agent as page content.
  class PageContent
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    FORMATS = %w[simplified text html].freeze
    CAPS = {"simplified" => 100_000, "text" => 100_000, "html" => 200_000}.freeze

    TOOLBAR_BEGIN = "BEGIN WAYBACK TOOLBAR INSERT"
    TOOLBAR_END = "END WAYBACK TOOLBAR INSERT"
    BLOCK_TAGS = %w[address article aside blockquote body br dd div dl dt fieldset figcaption figure footer form
      h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section table tr ul].freeze
    NON_CONTENT_TAGS = %w[script style noscript template head].freeze

    def self.call(html:, format:)
      new(html: html, format: format).call
    end

    def initialize(html:, format:)
      @html = html.to_s.scrub
      @format = format.to_s
    end

    def call
      unless FORMATS.include?(@format)
        return Result.new(success?: false, data: nil, errors: ["format must be one of #{FORMATS.join(", ")}"])
      end

      content = send(:"render_#{@format}", cleaned_document)
      cap = CAPS.fetch(@format)
      Result.new(success?: true, errors: [],
        data: {content: content[0, cap], length: content.length, truncated: content.length > cap})
    end

    private

    def cleaned_document
      doc = Nokogiri::HTML(@html)
      remove_toolbar_comments(doc)
      doc.css('[id^="wm-ipp"]').each(&:remove)
      doc
    end

    # Everything between the begin and end comments, the comments included. The
    # markers are siblings; a begin without an end removes nothing but itself.
    def remove_toolbar_comments(doc)
      doc.xpath("//comment()").each do |comment|
        next unless comment.content.include?(TOOLBAR_BEGIN)

        node = comment
        loop do
          following = node.next_sibling
          done = node.comment? && node.content.include?(TOOLBAR_END)
          node.remove
          break if done || following.nil?

          node = following
        end
      end
    end

    def render_html(doc) = doc.to_html

    def render_simplified(doc)
      simplified = Services::Html::SimplifierService.call(doc.to_html).to_s
      fragment = Nokogiri::HTML::DocumentFragment.parse(simplified)
      fragment.traverse do |node|
        next unless node.element?

        node.remove_attribute("class")
        node.remove_attribute("id")
      end
      prune(fragment)
      collapse(fragment.to_html)
    end

    # Elements that stay even when they hold no text: line and rule breaks, and the table and list
    # parts, where an empty cell or item is part of the structure.
    KEEP_EMPTY = %w[br hr td th tr li].freeze
    WRAPPERS = %w[div span].freeze

    # Removes elements with no text and nothing worth keeping inside, and unwraps div/span that only
    # wrap a single element, until nothing changes. Done here, not in SimplifierService, which the
    # list wizard depends on.
    def prune(fragment)
      loop do
        changed = false
        fragment.css("*").reverse_each do |node|
          next if node.parent.nil?

          if empty_element?(node)
            node.remove
            changed = true
          elsif pure_wrapper?(node)
            node.replace(node.element_children.first)
            changed = true
          end
        end
        break unless changed
      end
    end

    def empty_element?(node)
      return false if KEEP_EMPTY.include?(node.name)

      node.text.delete("\u00a0").strip.empty? && node.at_css(KEEP_EMPTY.join(",")).nil?
    end

    def pure_wrapper?(node)
      return false unless WRAPPERS.include?(node.name)

      node.element_children.size == 1 && node.children.none? { |child| child.text? && child.text.delete("\u00a0").strip.present? }
    end

    def render_text(doc)
      doc.css(NON_CONTENT_TAGS.join(",")).each(&:remove)
      out = +""
      walk(doc.at("body") || doc.root, out)
      collapse(out)
    end

    def walk(node, out)
      return unless node

      node.children.each do |child|
        if child.text?
          out << child.text
        elsif child.element?
          block = BLOCK_TAGS.include?(child.name)
          out << "\n" if block
          walk(child, out)
          out << "\n" if block
        end
      end
    end

    # Runs of blanks become one space, and blank lines collapse so a block never
    # leaves more than one empty line behind.
    def collapse(text)
      text.gsub(/[ \t ]+/, " ").gsub(/ ?\n[ \n]*/, "\n").gsub(/\n{3,}/, "\n\n").strip
    end
  end
end
