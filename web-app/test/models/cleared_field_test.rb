require "test_helper"

class ClearedFieldTest < ActiveSupport::TestCase
  setup do
    @book = books_books(:war_and_peace)
  end

  test "the enum has admin_ui and api" do
    assert_equal({"admin_ui" => 0, "api" => 1}, ClearedField.defined_enums["cleared_via"])
  end

  test "CLEARABLE lists the clearable fields per record type" do
    assert_equal %w[subtitle first_published_year original_language_id], ClearedField::CLEARABLE["Books::Book"]
    assert_equal %w[birth_year death_year], ClearedField::CLEARABLE["Books::Author"]
  end

  test "a record and field can be cleared once" do
    ClearedField.create!(clearable: @book, field_name: "subtitle", cleared_via: :api)
    duplicate = ClearedField.new(clearable: @book, field_name: "subtitle", cleared_via: :admin_ui)

    refute duplicate.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "the same field on another record, or another field on the same record, is fine" do
    ClearedField.create!(clearable: @book, field_name: "subtitle", cleared_via: :api)

    assert ClearedField.new(clearable: books_books(:crime_and_punishment), field_name: "subtitle", cleared_via: :api).valid?
    assert ClearedField.new(clearable: @book, field_name: "first_published_year", cleared_via: :api).valid?
  end

  test "cleared_by is optional and is nullified when the user is deleted" do
    user = User.create!(email: "clearer@example.com", name: "Clearer")
    row = ClearedField.create!(clearable: @book, field_name: "subtitle", cleared_via: :admin_ui, cleared_by: user)

    UserList.where(user_id: user.id).delete_all
    user.delete

    assert_nil row.reload.cleared_by_id
  end

  test "blank_value? is true for nil and empty-after-strip strings, false for 0" do
    assert ClearedField.blank_value?(nil)
    assert ClearedField.blank_value?("")
    assert ClearedField.blank_value?("  ")
    refute ClearedField.blank_value?(0)
    refute ClearedField.blank_value?("x")
    refute ClearedField.blank_value?(1869)
  end

  test "destroying a book deletes its rows" do
    book = ::Books::Book.create!(title: "Short Lived")
    ClearedField.create!(clearable: book, field_name: "subtitle", cleared_via: :api)

    assert_difference -> { ClearedField.count }, -1 do
      book.destroy!
    end
  end

  test "destroying an author deletes its rows" do
    author = ::Books::Author.create!(name: "Short Lived Author")
    ClearedField.create!(clearable: author, field_name: "birth_year", cleared_via: :api)

    assert_difference -> { ClearedField.count }, -1 do
      author.destroy!
    end
  end
end
