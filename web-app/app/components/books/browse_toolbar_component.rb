module Books
  class BrowseToolbarComponent < ViewComponent::Base
    TYPE_LABELS = {"genre" => "Genres", "location" => "Settings", "subject" => "Subjects"}.freeze
    SORT_LABELS = {"book_count" => "Most books", "name" => "Name"}.freeze

    def initialize(base_path:, sort:, type: nil, show_types: false)
      @base_path = base_path
      @sort = sort
      @type = type
      @show_types = show_types
    end

    private

    attr_reader :base_path, :sort, :type, :show_types

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

    # Both axes ride in every link so the toggles compose, and the defaults are
    # omitted so the default view has exactly one URL rather than three.
    def path_for(type:, sort:)
      query = {}
      query[:filter] = type if type.present? && type != Books::BrowseQuery::TYPES.first
      query[:sort] = sort if sort.present? && sort != Books::BrowseQuery::SORTS.first

      query.any? ? "#{base_path}?#{query.to_query}" : base_path
    end
  end
end
