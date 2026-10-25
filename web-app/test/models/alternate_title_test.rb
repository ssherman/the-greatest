require "test_helper"

# == Schema Information
#
# Table name: alternate_titles
#
#  id                 :bigint           not null, primary key
#  category           :integer
#  confidence         :float
#  decided_at         :datetime
#  decided_by         :integer
#  judged_at          :datetime
#  normalized_title   :string           not null
#  reason             :text
#  source             :integer          not null
#  status             :integer          default("kept"), not null
#  title              :string           not null
#  titleable_type     :string           not null
#  undo_checked_at    :datetime
#  verdict            :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  ai_chat_id         :bigint
#  decided_by_user_id :bigint
#  titleable_id       :bigint           not null
#
# Indexes
#
#  index_alternate_titles_on_ai_chat_id                       (ai_chat_id)
#  index_alternate_titles_on_decided_by_user_id               (decided_by_user_id)
#  index_alternate_titles_on_status                           (status)
#  index_alternate_titles_on_titleable_and_normalized_title   (titleable_type,titleable_id,normalized_title) UNIQUE
#  index_alternate_titles_on_titleable_type_and_titleable_id  (titleable_type,titleable_id)
#
# Foreign Keys
#
#  fk_rails_...  (ai_chat_id => ai_chats.id) ON DELETE => nullify
#  fk_rails_...  (decided_by_user_id => users.id) ON DELETE => nullify
#
class AlternateTitleTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
    @other = books_books(:crime_and_punishment)
    ::AlternateTitle.where(titleable: [@book, @other]).delete_all
  end

  test "normalized_title is set from title" do
    row = ::AlternateTitle.create!(titleable: @book, title: "“Don Quixote”", source: :admin)
    assert_equal ::Services::Books::Verification::Check.normalize("“Don Quixote”"), row.normalized_title
  end

  test "one row per book and normalized title" do
    ::AlternateTitle.create!(titleable: @book, title: "War and Peace", source: :legacy)
    assert_not ::AlternateTitle.new(titleable: @book, title: "WAR AND PEACE", source: :legacy).valid?
    assert ::AlternateTitle.new(titleable: @other, title: "WAR AND PEACE", source: :legacy).valid?
  end

  test "listed is kept and review in id order" do
    a = ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy)
    ::AlternateTitle.create!(titleable: @book, title: "B title", source: :legacy, status: :removed)
    c = ::AlternateTitle.create!(titleable: @book, title: "C title", source: :legacy, status: :review)
    assert_equal [a.title, c.title], @book.alternate_title_records.listed.pluck(:title)
  end

  test "unjudged is kept without a verdict" do
    unjudged = ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy)
    ::AlternateTitle.create!(titleable: @book, title: "B title", source: :legacy, verdict: :same_work)
    ::AlternateTitle.create!(titleable: @book, title: "C title", source: :legacy, status: :removed)
    assert_equal [unjudged], @book.alternate_title_records.unjudged.to_a
  end

  test "unjudged leaves out a row an admin already decided" do
    ::AlternateTitle.create!(titleable: @book, title: "A title", source: :legacy, decided_by: :admin, decided_at: Time.current)
    assert_empty @book.alternate_title_records.unjudged
  end

  test "rows are deleted with their book" do
    AlternateTitle.create!(titleable: @book, title: "Voyna", source: :legacy)
    AlternateTitle.create!(titleable: @other, title: "Prestuplenie", source: :legacy)
    book_id = @book.id

    @book.destroy!

    assert_equal 0, AlternateTitle.where(titleable_type: "Books::Book", titleable_id: book_id).count
    assert_equal 1, AlternateTitle.where(titleable: @other).count
  end

  test "normalize agrees with verification check" do
    ["  “Don Quixote”  ", "L\u2019Etranger", "ÉMILE"].each do |text|
      assert_equal ::Services::Books::Verification::Check.normalize(text), AlternateTitle.normalize(text)
    end
    [nil, "", "   "].each { |blank| assert_nil AlternateTitle.normalize(blank) }
  end
end
