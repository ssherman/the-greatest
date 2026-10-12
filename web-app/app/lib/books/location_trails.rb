# frozen_string_literal: true

module Books
  # "Chicago, Illinois, United States" for the book page (spec §3.4): each
  # direct location with its live ancestors, nearest first. The root (a
  # continent, or Fictional Location) is dropped when there is anything below
  # it -- every American book would otherwise end in "North America".
  # keep_root: true keeps the full chain (the AI trim wants the whole parent chain).
  # One query per tree level; trees are shallow.
  class LocationTrails
    def self.call(categories, keep_root: false)
      new(categories, keep_root: keep_root).call
    end

    def initialize(categories, keep_root: false)
      @categories = categories
      @keep_root = keep_root
    end

    def call
      by_id = load_ancestors
      @categories.to_h do |category|
        trail = [category]
        node = category
        while (parent = by_id[node.parent_id]) && trail.size < ::Books::Category::MAX_DEPTH
          trail << parent
          node = parent
        end
        trail.pop if !@keep_root && trail.size > 1 && trail.last.parent_id.nil?
        [category.id, trail]
      end
    end

    private

    def load_ancestors
      by_id = @categories.index_by(&:id)
      frontier = @categories.filter_map(&:parent_id)
      ::Books::Category::MAX_DEPTH.times do
        missing = frontier.uniq - by_id.keys
        break if missing.empty?

        found = ::Books::Category.active.where(id: missing).to_a
        found.each { |category| by_id[category.id] = category }
        frontier = found.filter_map(&:parent_id)
      end
      by_id
    end
  end
end
