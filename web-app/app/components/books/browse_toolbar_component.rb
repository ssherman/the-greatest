module Books
  class BrowseToolbarComponent < ViewComponent::Base
    TYPE_LABELS = {"genre" => "Genres", "location" => "Settings", "subject" => "Subjects"}.freeze
    SORT_LABELS = {"book_count" => "Most books", "name" => "A–Z"}.freeze
    # The turbo-frame the grid and the search results both render into, so a
    # search response (a full page) can be unwrapped to just this frame.
    RESULTS_FRAME = "categories_results".freeze

    def initialize(axis:, sort:, type: nil, active_type: type, show_types: false, show_sort: true, search: false, query: nil, browse_path: nil)
      @axis = axis
      @sort = sort
      @type = type
      # Which tab reads as current. Defaults to the type; the search page passes
      # nil because its results span all three, while `type` still rides in the
      # form to order them.
      @active_type = active_type
      @show_types = show_types
      @show_sort = show_sort
      @search = search
      @query = query
      @browse_path = browse_path
    end

    private

    attr_reader :axis, :sort, :type, :active_type, :show_types, :show_sort, :search, :query, :browse_path

    def type_links
      TYPE_LABELS.map do |value, label|
        {label: label, path: path_for(type: value, sort: sort), active: !active_type.nil? && value == active_type}
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
