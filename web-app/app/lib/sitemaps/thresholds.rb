module Sitemaps
  # Minimum ranked items a filter or category page needs before it is listed.
  # Methods rather than constants so tests can stub them.
  module Thresholds
    def self.filter_single = 10

    def self.filter_pair = 25
  end
end
