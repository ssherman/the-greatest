module Books
  class BrowseCardComponent < ViewComponent::Base
    # chain: ancestor names, root first (Books::CategoryChains). label: a short
    # type name shown on search results, where a card's type is not implied by
    # the page it sits on.
    def initialize(record:, count:, path:, chain: [], label: nil)
      @record = record
      @count = count
      @path = path
      @chain = chain
      @label = label
    end

    private

    attr_reader :record, :count, :path, :chain, :label

    # The card is one link, so the chain is part of its accessible name. A
    # sighted reader sees "Europe › France"; a screen reader hears "in Europe,
    # France" instead of "right-pointing angle quotation mark".
    def chain_content
      separator = safe_join([tag.span(" › ", aria: {hidden: true}), tag.span(", ", class: "sr-only")])
      safe_join([tag.span("in ", class: "sr-only"), safe_join(chain, separator)])
    end
  end
end
