module Books
  class BrowseToolbarComponent < ViewComponent::Base
    TYPE_LABELS = {"genre" => "Genres", "location" => "Settings", "subject" => "Subjects"}.freeze
    SORT_LABELS = {"book_count" => "Most books", "name" => "Name"}.freeze

    def initialize(axis:, sort:, type: nil, show_types: false)
      @axis = axis
      @sort = sort
      @type = type
      @show_types = show_types
    end

    private

    attr_reader :axis, :sort, :type, :show_types

    def type_links
      TYPE_LABELS.map do |value, label|
        {label: label, path: path_for(type: value, sort: sort), active: value == type}
      end
    end

    def sort_links
      SORT_LABELS.map do |value, label|
        {label: label, path: path_for(type: type, sort: value), active: value == sort}
      end
    end

    # Both axes ride in every link so the toggles compose. BrowsePath omits the
    # defaults, so the default view has exactly one URL rather than three.
    def path_for(type:, sort:)
      Books::BrowsePath.call(axis: axis, type: type, sort: sort)
    end
  end
end
