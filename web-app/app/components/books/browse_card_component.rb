module Books
  class BrowseCardComponent < ViewComponent::Base
    def initialize(record:, count:, path:)
      @record = record
      @count = count
      @path = path
    end

    private

    attr_reader :record, :count, :path
  end
end
