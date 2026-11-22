# frozen_string_literal: true

module Services
  # Turns the HTML a fetched page came back as into what an agent reads: `simplified` (structure
  # kept, scripts, styling and most attributes gone), `text`, or `html` (as returned). Every format
  # is capped; `length` is the length of the content before the output cap. The Wayback Machine's
  # injected toolbar is removed first, so it never reaches an agent as page content.
  #
  # Our own single-pass sanitiser, not Services::Html::SimplifierService: that one drops forms,
  # figures, headers, cite, blockquote and pre with their contents, which empties real pages. Each
  # format is one linear walk of the parsed document: nothing is replaced in the tree, the output is
  # appended to a buffer, and an element that turns out empty is cut back off its end. The web
  # process that runs this also serves live traffic, so a 5 MB page must not take quadratic time:
  # simplified and text read at most MAX_INPUT characters, and `truncated` says when they did.
  class PageContent
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    FORMATS = %w[simplified text html].freeze
    CAPS = {"simplified" => 100_000, "text" => 100_000, "html" => 200_000}.freeze
    MAX_INPUT = 2_000_000

    TOOLBAR_BEGIN = "BEGIN WAYBACK TOOLBAR INSERT"
    TOOLBAR_END = "END WAYBACK TOOLBAR INSERT"

    # Removed with their contents.
    DROP = %w[script style noscript template svg canvas iframe object embed img picture video audio source
      track link meta input select textarea button head].freeze

    INLINE = %w[a strong em b i code q cite abbr time sup sub small mark u s].freeze
    # Kept in `simplified`; any other element is unwrapped (its children stay).
    KEEP = (INLINE + %w[h1 h2 h3 h4 h5 h6 p ul ol li dl dt dd table thead tbody tfoot tr td th caption blockquote
      pre br hr article section main header footer nav aside figure figcaption details summary div]).freeze
    # Stay even when they hold no text: breaks, rules, and the table and list parts, where an empty
    # cell or item is part of the structure.
    KEEP_EMPTY = %w[br hr td th tr li].freeze
    VOID = %w[br hr].freeze

    # Start a new line in `text`.
    TEXT_BLOCKS = %w[address article aside blockquote body br dd div dl dt fieldset figcaption figure footer form
      h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section table tr ul caption details summary].freeze

    ESCAPES = {"&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;"}.freeze

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

      cut_input = @format != "html" && @html.length > MAX_INPUT
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

    # The range from the begin comment to the end comment, when the end is a later sibling. A begin
    # with no end among its siblings removes only itself: a truncated page, or a wrapper that closed
    # between the markers, must not lose the content after it. (The toolbar's own elements go by id.)
    def remove_toolbar_comments(doc)
      doc.xpath("//comment()").each do |comment|
        next unless comment.parent && comment.content.include?(TOOLBAR_BEGIN)

        range = [comment]
        node = comment.next_sibling
        found = false
        while node
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
      emit(doc)
      collapse(@buf)
    end

    def emit(node)
      node.children.each do |child|
        if child.text? || child.cdata?
          emit_text(child.text)
        elsif child.element?
          emit_element(child)
        end
      end
    end

    def emit_text(text)
      return if text.empty?

      @signal += 1 if text.match?(/[^\s ]/)
      @buf << text.gsub(/[\s ]+/, " ").gsub(/[&<>]/, ESCAPES)
    end

    def emit_element(el)
      name = el.name
      return if DROP.include?(name)
      return emit(el) unless KEEP.include?(name)
      return emit(el) if name == "a" && el["href"].to_s.strip.empty?
      return emit(el) if name == "div" && pure_wrapper?(el)

      start = @buf.bytesize
      signal = @signal
      block = !INLINE.include?(name)
      @buf << "\n" if block
      @buf << "<" << name << attributes(el) << ">"
      unless VOID.include?(name)
        emit(el)
        @buf << "</" << name << ">"
      end
      @buf << "\n" if block

      if KEEP_EMPTY.include?(name)
        @signal += 1
      elsif @signal == signal
        @buf.bytesplice(start..-1, "")
      end
    end

    # A div that is its parent's only element and wraps a single element with no text of its own adds
    # nesting and nothing else. A div with element siblings is an entry, and stays a block.
    def pure_wrapper?(el)
      return false unless el.previous_element.nil? && el.next_element.nil? && el.element_children.size == 1

      el.children.none? { |child| child.text? && child.text.match?(/[^\s ]/) }
    end

    def attributes(el)
      case el.name
      when "a"
        href = el["href"].to_s.strip
        href.match?(/\Ajavascript:/i) ? "" : %( href="#{href.gsub(/[&<>"]/, ESCAPES)}")
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
          @buf << (in_pre ? child.text : child.text.gsub(/[\s ]+/, " "))
        elsif child.element?
          name = child.name
          next if DROP.include?(name)

          block = TEXT_BLOCKS.include?(name)
          @buf << "\n" if block
          if %w[td th].include?(name) && %w[td th].include?(child.previous_element&.name)
            @buf << " | "
          end
          walk_text(child, in_pre || name == "pre")
          @buf << "\n" if block
        end
      end
    end

    # Runs of blanks become one space and blank lines collapse, so a block never leaves more than
    # one line break behind.
    def collapse(text)
      text.gsub(/[ \t ]+/, " ").gsub(/ ?\n[ \n]*/, "\n").strip
    end
  end
end
