module Books
  class FilterPaneComponent < ViewComponent::Base
    NOUNS = {
      "genre" => "genres", "audience" => "audiences", "subject" => "subjects",
      "location" => "settings", "country" => "origins"
    }.freeze

    # type is a category type or "country". results_src is present only for the
    # long-tail types (subject, setting), which search server-side.
    def initialize(type:, rows:, results_src: nil)
      @type = type.to_s
      @rows = Array(rows)
      @results_src = results_src
    end

    private

    attr_reader :type, :rows, :results_src

    def axis
      (type == "country") ? "country" : "category"
    end

    def pane_frame_id
      "books_filter_pane_#{type}"
    end

    def results_frame_id
      "books_filter_results_#{type}"
    end

    def noun
      NOUNS.fetch(type)
    end

    # Only these lists are short enough to ship whole and filter in the browser.
    def client_filtered?
      %w[genre audience country].include?(type)
    end

    # The audience/subject/setting indexes have no named route helpers.
    def browse_path
      case type
      when "genre" then helpers.books_categories_path
      when "subject" then "/categories/subjects"
      when "location" then "/categories/settings"
      when "audience" then "/categories/audiences"
      else helpers.books_countries_path
      end
    end
  end
end
