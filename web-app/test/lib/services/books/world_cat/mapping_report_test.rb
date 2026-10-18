require "test_helper"

module Services
  module Books
    module WorldCat
      class MappingReportTest < ActiveSupport::TestCase
        setup do
          @map = ::Books::WorldCat::GenreMap.load(file_fixture("worldcat_genre_map.yml"))
          @out = Rails.root.join("tmp", "worldcat-genre-mapping-test-#{SecureRandom.hex(6)}.md")
        end

        teardown { File.delete(@out) if File.exist?(@out) }

        test "writes the top table and the unplaced list ranked by books" do
          result = MappingReport.call(map: @map, out_path: @out, top: 3)
          assert result.success?
          assert_equal({genre: 3, audience: 0, subject: 1, drop: 2}, result.data[:counts])
          assert_equal %w[Fiction Romans History], result.data[:top].map { |row| row[:term] }
          assert_equal %w[History Bildungsromans], result.data[:unplaced].map { |row| row[:term] }
          page = File.read(@out)
          assert_match(/^# WorldCat genre mapping/, page)
          assert_match(/\| Romans \| 50 \| 40 \| genre \| Fiction \|/, page)
          assert_match(/## Terms with no genre/, page)
          assert_no_match(/Large type books.*not_a_genre/, page)
        end

        test "audience verdicts are counted and shown with their audience" do
          map = ::Books::WorldCat::GenreMap.new("terms" => {
            "Young adult fiction" => {"verdict" => "audience", "audience" => "Young Adult", "uses" => 5, "books" => 2}
          })

          result = MappingReport.call(map: map, out_path: @out)

          assert_equal 1, result.data[:counts][:audience]
          assert_includes File.read(@out), "| Young adult fiction | 5 | 2 | audience | Young Adult |"
        end
      end
    end
  end
end
