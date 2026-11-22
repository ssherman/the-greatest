# frozen_string_literal: true

module Services
  # Turns the HTML a fetched page came back as into what an agent reads: `simplified` (structure
  # kept, scripts, styling and most attributes gone), `text`, or `html` (as returned). Every format
  # is capped; `length` is the length of the content that was processed, before the output cap. The
  # Wayback Machine's injected toolbar is removed first, so it never reaches an agent as page content.
  #
  # Our own single-pass sanitiser, not Services::Html::SimplifierService: that one drops forms,
  # figures, headers, cite, blockquote and pre with their contents, which empties real pages. Each
  # format is one linear walk of the parsed document: nothing is replaced in the tree, the output is
  # appended to a buffer, and an element that turns out empty is cut back off its end. The web
  # process that runs this also serves live traffic, so a 5 MB page must not take quadratic time:
  # every format reads at most MAX_INPUT characters, and `truncated` says when it did.
  class PageContent
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    FORMATS = %w[simplified text html].freeze
    CAPS = {"simplified" => 100_000, "text" => 100_000, "html" => 200_000}.freeze
    MAX_INPUT = 2_000_000

    TOOLBAR_BEGIN = "BEGIN WAYBACK TOOLBAR INSERT"
    TOOLBAR_END = "END WAYBACK TOOLBAR INSERT"

    # Removed with their contents. (img keeps its alt text and select its options; see below.)
    DROP = %w[script style noscript template svg canvas iframe object embed picture video audio source
      track link meta input textarea button head].freeze

    INLINE = %w[a strong em b i code q cite abbr time sup sub small mark u s].freeze
    # Kept in `simplified`; any other element is unwrapped (its children stay).
    KEEP = (INLINE + %w[h1 h2 h3 h4 h5 h6 p ul ol li dl dt dd table thead tbody tfoot tr td th caption blockquote
      pre br hr article section main header footer nav aside figure figcaption details summary div legend]).freeze
    # Stay even when they hold no text: breaks, rules, and the table and list parts, where an empty
    # cell or item is part of the structure.
    KEEP_EMPTY = %w[br hr td th tr li].freeze
    VOID = %w[br hr].freeze

    # Start a new line in `text`.
    TEXT_BLOCKS = %w[address article aside blockquote body br dd div dl dt fieldset figcaption figure footer form
      h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section table tr ul caption details summary legend].freeze

    ESCAPES = {"&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;"}.freeze
    BLANK = /[\s ]+/
    SAFE_HREF_SCHEMES = %w[http https mailto].freeze

    def self.call(html:, format:)
      new(html: html, format: format).call
    end

    def initialize(html:, format:)
      @html = html.to_s.scrub
      @format = format.to_s
      @signal = 0
    end

    def call
      unless FORMATS.include?(@format)
        return Result.new(success?: false, data: nil, errors: ["format must be one of #{FORMATS.join(", ")}"])
      end

      cut_input = @html.length > MAX_INPUT
      @html = @html[0, MAX_INPUT] if cut_input

      content = send(:"render_#{@format}", cleaned_document)
      cap = CAPS.fetch(@format)
      Result.new(success?: true, errors: [],
        data: {content: content[0, cap], length: content.length, truncated: cut_input || content.length > cap})
    end

    private

    def cleaned_document
      doc = Nokogiri::HTML(@html)
      remove_toolbar_comments(doc)
      doc.css('[id^="wm-ipp"]').each(&:unlink)
      doc
    end

    # The range from the begin comment to the end comment, when the end is a later sibling and no
    # other begin comes first. A begin with no end removes only itself: a truncated page, or a wrapper
    # that closed between the markers, must not lose the content after it. The scan stops at the next
    # begin, so every sibling is visited once however many unmatched markers a page carries. (The
    # toolbar's own elements go by id.)
    def remove_toolbar_comments(doc)
      doc.xpath("//comment()").each do |comment|
        next unless comment.parent && comment.content.include?(TOOLBAR_BEGIN)

        range = [comment]
        node = comment.next_sibling
        found = false
        while node
          break if node.comment? && node.content.include?(TOOLBAR_BEGIN)

          range << node
          if node.comment? && node.content.include?(TOOLBAR_END)
            found = true
            break
          end
          node = node.next_sibling
        end
        (found ? range : [comment]).each(&:unlink)
      end
    end

    def render_html(doc) = doc.to_html

    def render_simplified(doc)
      @buf = +""
      emit(doc, false)
      @buf.strip
    end

    def emit(node, pre)
      node.children.each do |child|
        if child.text? || child.cdata?
          emit_text(child.text, pre)
        elsif child.element?
          emit_element(child, pre)
        end
      end
    end

    # Whitespace is collapsed here, as text is written, and the assembled output is never rewritten
    # afterwards: an attribute value is written once, untouched. Inside <pre> the text is as it came.
    def emit_text(text, pre)
      return if text.empty?

      @signal += 1 if text.match?(/[^\s\u00a0]/)
      @buf << escape_text(pre ? text : collapse_blanks(text))
    end

    def escape_text(text) = text.gsub(/[&<>]/, ESCAPES)

    # Runs of blanks become one space, and none starts a line or follows another.
    def collapse_blanks(text)
      text = text.gsub(BLANK, " ")
      text = text.delete_prefix(" ") if at_line_start_or_space?
      text
    end

    def at_line_start_or_space?
      last = @buf.getbyte(-1)
      last.nil? || last == 32 || last == 10
    end

    # A line break, never two in a row and never after trailing spaces.
    def newline!
      @buf.chop! while @buf.getbyte(-1) == 32
      @buf << "\n" unless @buf.empty? || @buf.getbyte(-1) == 10
    end

    # Keeps emitted alt text and option labels from running into what is next to them.
    def emit_alt(text, pre)
      text = collapse_blanks(text).strip
      return if text.empty?

      @signal += 1
      @buf << " " unless at_line_start_or_space? || @buf.getbyte(-1) == 62
      @buf << escape_text(text)
    end

    def emit_element(el, pre)
      name = el.name
      return if DROP.include?(name)
      return emit_alt(el["alt"].to_s, pre) if name == "img"
      return emit_options(el) if name == "select"
      return emit(el, pre) unless KEEP.include?(name)
      return emit(el, pre) if name == "a" && safe_href(el).nil?
      return emit(el, pre) if name == "div" && pure_wrapper?(el)

      block = !INLINE.include?(name)
      newline! if block
      start = @buf.bytesize
      signal = @signal
      @buf << "<" << name << attributes(el) << ">"
      unless VOID.include?(name)
        emit(el, pre || name == "pre")
        @buf << "</" << name << ">"
      end
      newline! if block

      if KEEP_EMPTY.include?(name)
        @signal += 1
      elsif @signal == signal
        @buf.bytesplice(start..-1, "")
      end
    end

    # A jump menu's options are links in everything but name: give them as a list.
    def emit_options(select)
      labels = option_labels(select)
      return if labels.empty?

      @signal += 1
      newline!
      @buf << "<ul>"
      labels.each { |label| @buf << "<li>" << escape_text(label) << "</li>\n" }
      @buf << "</ul>"
      newline!
    end

    def option_labels(select)
      select.css("option").map { |option| option.text.gsub(BLANK, " ").strip }.reject(&:empty?)
    end

    # A div that is its parent's only element and wraps a single element with no text of its own adds
    # nesting and nothing else. A div with element siblings is an entry, and stays a block.
    def pure_wrapper?(el)
      return false unless el.previous_element.nil? && el.next_element.nil? && el.element_children.size == 1

      el.children.none? { |child| child.text? && child.text.match?(/[^\s ]/) }
    end

    # The href, only when it is relative or http, https or mailto; nil otherwise. Browsers ignore
    # leading control characters and whitespace and tabs or newlines inside the scheme, so the check
    # does too. Whitespace left inside the value is percent-escaped.
    # Control characters and blanks off both ends, as a browser does. Linear: the end is trimmed on
    # the reversed string, where it is an anchored match at the start.
    def trim_href(value)
      value = value.sub(/\A[\x00-\x20\u00a0]+/, "")
      value.reverse.sub(/\A[\x00-\x20\u00a0]+/, "").reverse
    end

    def safe_href(el)
      href = trim_href(el["href"].to_s)
      return nil if href.empty?

      # Whatever precedes the first colon, when no path, query or fragment comes before it, is a
      # scheme, whatever characters it holds; only the allowlisted ones pass.
      scheme = href.delete("\x00-\x1f").match(/\A([^\/?#:]*):/)&.[](1)
      return nil if scheme && !SAFE_HREF_SCHEMES.include?(scheme.downcase)

      href.gsub(/[\s ]/) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
    end

    def attributes(el)
      case el.name
      when "a"
        %( href="#{safe_href(el).gsub(/[&<>"]/, ESCAPES)}")
      when "td", "th"
        %w[colspan rowspan].filter_map { |attr| %( #{attr}="#{el[attr]}") if el[attr].to_s.match?(/\A\d{1,4}\z/) }.join
      else
        ""
      end
    end

    def render_text(doc)
      @buf = +""
      walk_text(doc, false)
      @buf.strip
    end

    def walk_text(node, in_pre)
      node.children.each do |child|
        if child.text? || child.cdata?
          @buf << (in_pre ? child.text : collapse_blanks(child.text))
        elsif child.element?
          walk_text_element(child, in_pre)
        end
      end
    end

    def walk_text_element(el, in_pre)
      name = el.name
      return if DROP.include?(name)
      return emit_alt_text(el["alt"].to_s) if name == "img"
      if name == "select"
        return option_labels(el).each { |label|
          newline!
          @buf << label
          newline!
        }
      end

      block = TEXT_BLOCKS.include?(name)
      newline! if block
      if %w[td th].include?(name) && %w[td th].include?(el.previous_element&.name)
        @buf.chop! while @buf.getbyte(-1) == 32
        @buf << " | "
      end
      walk_text(el, in_pre || name == "pre")
      newline! if block
    end

    def emit_alt_text(alt)
      alt = collapse_blanks(alt).strip
      return if alt.empty?

      @buf << " " unless at_line_start_or_space?
      @buf << alt
    end
  end
end
