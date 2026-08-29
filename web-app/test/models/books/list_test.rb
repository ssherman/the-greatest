require "test_helper"

# == Schema Information
#
# Table name: lists
#
#  id                    :bigint           not null, primary key
#  activated_at          :datetime
#  auto_generated_kind   :integer
#  category_specific     :boolean
#  creator_specific      :boolean
#  description           :text
#  estimated_quality     :integer          default(0), not null
#  high_quality_source   :boolean
#  items_json            :jsonb
#  location_specific     :boolean
#  name                  :string           not null
#  num_years_covered     :integer
#  number_of_voters      :integer
#  raw_content           :text
#  simplified_content    :text
#  source                :string
#  source_country_origin :string
#  status                :integer          default(0), not null
#  submitted_at          :datetime
#  submitter_email       :string
#  submitter_ip          :string
#  type                  :string           not null
#  url                   :string
#  voter_count_estimated :boolean
#  voter_count_unknown   :boolean
#  voter_names_unknown   :boolean
#  wizard_state          :jsonb
#  year_published        :integer
#  yearly_award          :boolean
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  musicbrainz_series_id :string
#  submitted_by_id       :bigint
#
# Indexes
#
#  index_lists_on_activated_at                  (activated_at)
#  index_lists_on_submitted_at                  (submitted_at)
#  index_lists_on_submitted_by_id               (submitted_by_id)
#  index_lists_on_type_and_auto_generated_kind  (type,auto_generated_kind) UNIQUE WHERE (auto_generated_kind IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (submitted_by_id => users.id)
#
module Books
  class ListTest < ActiveSupport::TestCase
    # books_countries(:french) carries labels: [western]
    # books_countries(:japanese) carries labels: [asian]
    # books_books(:crime_and_punishment) has no books_book_countries row at all
    def setup
      @list = ::Books::List.create!(name: "Western Percentage Test List", status: :approved)
    end

    def add_book(book, position)
      ListItem.create!(list: @list, listable: book, position: position)
    end

    test "returns 100.0 when every book is western" do
      add_book(books_books(:war_and_peace), 1)
      add_book(books_books(:got), 2)

      assert_in_delta 100.0, @list.percentage_western, 0.001
    end

    test "returns the western share rounded to two places" do
      add_book(books_books(:war_and_peace), 1)   # french -> western
      add_book(books_books(:got), 2)             # french -> western
      add_book(books_books(:of_mice_and_men), 3) # japanese -> not western

      # 2 of 3 = 66.666... -> 66.67
      assert_in_delta 66.67, @list.percentage_western, 0.001
    end

    test "counts a book with no country as not western" do
      add_book(books_books(:war_and_peace), 1)         # western
      add_book(books_books(:crime_and_punishment), 2)  # no country row

      assert_in_delta 50.0, @list.percentage_western, 0.001
    end

    test "returns 0.0 when no book is western" do
      add_book(books_books(:of_mice_and_men), 1)

      assert_in_delta 0.0, @list.percentage_western, 0.001
    end

    test "returns nil when the list has no items" do
      assert_nil @list.percentage_western
    end

    test "ignores items with no resolved book" do
      add_book(books_books(:war_and_peace), 1)
      ListItem.create!(list: @list, listable_type: "Books::Book", listable_id: nil, position: 2)

      # The unresolved item is excluded from both numerator and denominator.
      assert_in_delta 100.0, @list.percentage_western, 0.001
    end
  end
end
