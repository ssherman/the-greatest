module Pagination
  # Turns a page number into a path. Takes base_path as a constructor argument so
  # a caller that computes it some other way -- e.g. from filter state -- can reuse
  # this unchanged.
  class PathBuilder
    PAGE_SEGMENT = %r{/page/\d+\z}

    def self.from_request(request)
      new(base_path: request.path.sub(PAGE_SEGMENT, ""))
    end

    def initialize(base_path:)
      @base_path = base_path.chomp("/").presence || "/"
    end

    attr_reader :base_path

    # pagy invokes this through its :page_path option.
    def call(page)
      page = page.to_i
      return base_path if page <= 1

      (base_path == "/") ? "/page/#{page}" : "#{base_path}/page/#{page}"
    end
  end
end
