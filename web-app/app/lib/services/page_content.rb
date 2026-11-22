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
    # Whitespace inside <pre> is swapped for private-use characters while the output is collapsed,
    # then swapped back. The input never carries them (they are deleted on the way in).
    PRE_FROM = " \n\t"
    PRE_TO = ""
    BLANK = /[\s ]+/
    SAFE_HREF_SCHEMES = %w[http https mailto].freeze

    def self.call(html:, format:)
      new(html: html, format: format).call
    end

    def initialize(html:, format:)
      @html = html.to_s.scrub.delete(PRE_TO)
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
      collapse(@buf)
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

    def emit_text(text, pre)
      return if text.empty?

      @signal += 1 if text.match?(/[^\s ]/)
      text = pre ? text.tr(PRE_FROM, PRE_TO) : text.gsub(BLANK, " ")
      @buf << text.gsub(/[&<>]/, ESCAPES)
    end

    def emit_element(el, pre)
      name = el.name
      return if DROP.include?(name)
      return emit_text(el["alt"].to_s, pre) if name == "img"
      return emit_options(el) if name == "select"
      return emit(el, pre) unless KEEP.include?(name)
      return emit(el, pre) if name == "a" && safe_href(el).nil?
      return emit(el, pre) if name == "div" && pure_wrapper?(el)

      start = @buf.bytesize
      signal = @signal
      block = !INLINE.include?(name)
      @buf << "\n" if block
      @buf << "<" << name << attributes(el) << ">"
      unless VOID.include?(name)
        emit(el, pre || name == "pre")
        @buf << "</" << name << ">"
      end
      @buf << "\n" if block

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
      @buf << "\n<ul>"
      labels.each { |label| @buf << "<li>" << label.gsub(/[&<>]/, ESCAPES) << "</li>\n" }
      @buf << "</ul>\n"
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
    # does too. The value is percent-escaped for whitespace, which keeps the later whitespace
    # collapse from rewriting it.
    def safe_href(el)
      href = el["href"].to_s.sub(/\A[\x00-\x20 ]+/, "")
      return nil if href.empty?

      scheme = href.delete("\x00-\x1f").match(/\A([a-z][a-z0-9+.-]*):/i)&.[](1)
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
      collapse(@buf)
    end

    def walk_text(node, in_pre)
      node.children.each do |child|
        if child.text? || child.cdata?
          @buf << (in_pre ? child.text.tr(PRE_FROM, PRE_TO) : child.text.gsub(BLANK, " "))
        elsif child.element?
          walk_text_element(child, in_pre)
        end
      end
    end

    def walk_text_element(el, in_pre)
      name = el.name
      return if DROP.include?(name)
      return @buf << el["alt"].to_s.gsub(BLANK, " ") if name == "img"
      return option_labels(el).each { |label| @buf << "\n" << label << "\n" } if name == "select"

      block = TEXT_BLOCKS.include?(name)
      @buf << "\n" if block
      @buf << " | " if %w[td th].include?(name) && %w[td th].include?(el.previous_element&.name)
      walk_text(el, in_pre || name == "pre")
      @buf << "\n" if block
    end

    # Runs of blanks become one space and blank lines collapse, so a block never leaves more than
    # one line break behind; whitespace inside <pre> comes back untouched.
    def collapse(text)
      text.gsub(/[ \t ]+/, " ").gsub(/ ?\n[ \n]*/, "\n").strip.tr(PRE_TO, PRE_FROM)
    end
  end
end
