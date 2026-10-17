module Books
  class BrowseCardComponent < ViewComponent::Base
    CHAIN_SEPARATOR = " › ".freeze

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

    def chain_text
      chain.join(CHAIN_SEPARATOR)
    end
  end
end
