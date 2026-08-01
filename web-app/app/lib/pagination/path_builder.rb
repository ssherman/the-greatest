module Pagination
  # Turns a page number into a path. Takes base_path as a constructor argument so
  # a caller that computes it some other way -- e.g. from filter state -- can reuse
  # this unchanged.
  class PathBuilder
    PAGE_SEGMENT = %r{/page/\d+\z}

    def self.from_request(request)
      format = request.path_parameters[:format]
      path = request.path
      path = path.delete_suffix(".#{format}") if format.present?
      new(base_path: path.sub(PAGE_SEGMENT, ""), format: format)
    end

    def initialize(base_path:, format: nil)
      @base_path = base_path.chomp("/").presence || "/"
      @format = format
    end

    attr_reader :base_path

    # pagy invokes this through its :page_path option.
    def call(page)
      page = page.to_i
      path = path_for(page)

      @format.present? ? "#{path}.#{@format}" : path
    end

    private

    def path_for(page)
      return base_path if page <= 1

      (base_path == "/") ? "/page/#{page}" : "#{base_path}/page/#{page}"
    end
  end
end
