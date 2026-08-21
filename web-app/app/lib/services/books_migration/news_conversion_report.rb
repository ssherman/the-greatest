module Services
  module BooksMigration
    # Dumps every legacy blog_posts row's HTML next to its NewsBodyConverter
    # Markdown, for hand review before data_migration:news_posts runs for real.
    # Read-only against the legacy DB; writes nothing to news_posts.
    #
    # Pulled out of the news_posts_diff rake task so the task stays a thin
    # printing wrapper -- see CLAUDE.md's "rake tasks stay thin" rule.
    class NewsConversionReport
      DEFAULT_PATH = Rails.root.join("tmp", "news_posts_conversion.txt")

      def self.call(path: DEFAULT_PATH)
        new(path).call
      end

      def initialize(path)
        @path = path
      end

      def call
        File.open(@path, "w") do |f|
          ::LegacyBooks::BlogPost.order(:id).each do |legacy|
            html = legacy.body_html
            f.puts "=" * 78
            f.puts "##{legacy.id}  #{legacy.title}  (#{legacy.slug})"
            f.puts "round-trips: #{NewsBodyConverter.round_trips?(html)}"
            f.puts "-" * 30 + " LEGACY HTML " + "-" * 30
            f.puts html
            f.puts "-" * 30 + " MARKDOWN " + "-" * 33
            f.puts NewsBodyConverter.call(html)
            f.puts
          end
        end
        @path
      end
    end
  end
end
