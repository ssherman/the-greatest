module Books
  class FilterPaneComponent < ViewComponent::Base
    def initialize(axis:, facet_rows: [], results_src: nil)
      @axis = axis.to_s
      @facet_rows = Array(facet_rows)
      @results_src = results_src
    end

    private

    attr_reader :axis, :facet_rows, :results_src

    def pane_frame_id
      "books_filter_pane_#{axis}"
    end

    def results_frame_id
      "books_filter_results_#{axis}"
    end

    def browse_path
      (axis == "category") ? helpers.books_genres_path : helpers.books_countries_path
    end

    def browse_label
      (axis == "category") ? "Browse all genres" : "Browse all origins"
    end
  end
end
