require "test_helper"

module Services
  module Books
    module GenrePlan
      class ReportTest < ActiveSupport::TestCase
        test "lists decisions by action and summarises each split" do
          sff = ::Books::Category.create!(name: "Science Fiction Fantasy", category_type: :genre)
          books = %i[war_and_peace crime_and_punishment got of_mice_and_men clash].map { |name| books_books(name) }
          books.each { |book| CategoryItem.create!(category: sff, item: book) }
          plan = PlanFile.new({"run" => "g", "decisions" => {
            1 => {"name" => "Ebooks", "action" => "delete", "books" => 52, "saved_searches" => 3, "reason" => "A format."},
            2 => {"name" => "Space Opera", "action" => "merge", "into" => "Science Fiction", "books" => 9},
            sff.id => {"name" => sff.name, "action" => "split", "into" => ["Science Fiction", "Fantasy"], "books" => 5}
          }})
          assignments = Assignments.new([
            [books[0].id, sff.id, ["Fantasy"]], [books[1].id, sff.id, ["Science Fiction", "Fantasy"]],
            [books[2].id, sff.id, []], [books[3].id, sff.id, :unknown]
          ])

          lines = Report.call(plan: plan, assignments: assignments).data[:lines]
          text = lines.join("\n")

          assert_includes text, "1 Ebooks (books 52, saved searches 3) A format."
          assert_includes text, "2 Space Opera -> Science Fiction (books 9)"
          assert_includes text, "== split Science Fiction Fantasy (5 books)"
          assert_includes lines, "Fantasy: 1"
          assert_includes lines, "several: 1"
          assert_includes lines, "none: 1"
          assert_includes lines, "unknown: 1"
          assert_includes lines, "unanswered: 1"
          assert_includes lines, "Fantasy (any): 2"
          assert_includes lines, "Science Fiction (any): 1"
          assert_includes text, books[0].title
        end

        test "a delete with no saved searches still shows the count" do
          plan = PlanFile.new({"run" => "g", "decisions" => {1 => {"name" => "Ebooks", "action" => "delete", "books" => 2}}})

          text = Report.call(plan: plan, assignments: Assignments.new([])).data[:lines].join("\n")

          assert_includes text, "1 Ebooks (books 2, saved searches 0)"
        end
      end
    end
  end
end
