# frozen_string_literal: true

module Wikipedia
  # Pulls the few book-relevant fields out of an article's top-level
  # {{Infobox ...}} template. Wikitext is not parsed in general: the block is
  # found by brace counting and split on top-level pipes.
  module Infobox
    FIELDS = %w[country language genre subject set_in].freeze
    LIST_TEMPLATES = /\{\{\s*(?:plainlist|ubl|hlist|unbulleted list|flatlist)\s*\|(.*?)\}\}/im

    def self.fields(wikitext)
      block = block_for(wikitext.to_s)
      return {} unless block

      split_params(block).each_with_object({}) do |param, result|
        name, value = param.split("=", 2)
        next unless value

        key = name.strip.downcase.tr(" ", "_")
        next unless FIELDS.include?(key)

        cleaned = clean(value)
        result[key] = cleaned unless cleaned.empty?
      end
    end

    # The text between the outer braces of the first {{Infobox ...}}.
    def self.block_for(text)
      start = text.index(/\{\{\s*infobox/i)
      return nil unless start

      depth = 0
      i = start
      while i < text.length
        pair = text[i, 2]
        if pair == "{{"
          depth += 1
          i += 2
        elsif pair == "}}"
          depth -= 1
          return text[(start + 2)...i] if depth.zero?
          i += 2
        else
          i += 1
        end
      end
      nil
    end
    private_class_method :block_for

    # Splits on pipes that are not inside {{ }} or [[ ]].
    def self.split_params(block)
      parts = [+""]
      depth = 0
      i = 0
      while i < block.length
        pair = block[i, 2]
        if ["{{", "[["].include?(pair)
          depth += 1
          parts.last << pair
          i += 2
        elsif ["}}", "]]"].include?(pair)
          depth -= 1
          parts.last << pair
          i += 2
        elsif block[i] == "|" && depth.zero?
          parts << +""
          i += 1
        else
          parts.last << block[i]
          i += 1
        end
      end
      parts
    end
    private_class_method :split_params

    def self.clean(value)
      text = value.gsub(%r{<ref[^>]*/>}i, "").gsub(%r{<ref[^>]*>.*?</ref>}mi, "")
      text = text.gsub(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/, '\1')
      text = text.gsub(%r{<br\s*/?>}i, ", ")
      text = text.gsub(LIST_TEMPLATES) { list_items(Regexp.last_match(1)) }
      text = text.gsub(/\{\{.*?\}\}/m, "")
      text.gsub(/\s+/, " ").strip
    end
    private_class_method :clean

    def self.list_items(body)
      body.split(/\n\s*\*|\||\A\s*\*/).map(&:strip).reject(&:empty?).join(", ")
    end
    private_class_method :list_items
  end
end
