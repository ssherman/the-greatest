require "test_helper"

# == Schema Information
#
# Table name: books_book_countries
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  book_id    :bigint           not null
#  country_id :bigint           not null
#
# Indexes
#
#  index_books_book_countries_on_book_id                 (book_id)
#  index_books_book_countries_on_book_id_and_country_id  (book_id,country_id) UNIQUE
#  index_books_book_countries_on_country_id              (country_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (country_id => books_countries.id)
#
module Books
  class BookCountryTest < ActiveSupport::TestCase
    test "requires a book and a country" do
      link = Books::BookCountry.new

      assert_not link.valid?
      assert_includes link.errors[:book], "must exist"
      assert_includes link.errors[:country], "must exist"
    end

    test "a book reads its countries through the join" do
      assert_equal [books_countries(:french)], books_books(:war_and_peace).countries.to_a
    end

    test "a country reads its books through the join" do
      titles = books_countries(:french).books.pluck(:title).sort

      assert_equal [books_books(:got).title, books_books(:war_and_peace).title].sort, titles
    end

    test "creating a link increments the country book_count" do
      country = Books::Country.create!(name: "Peruvian")
      book = Books::Book.create!(title: "Counter Cache Probe")

      assert_difference -> { country.reload.book_count }, 1 do
        Books::BookCountry.create!(book: book, country: country)
      end
    end

    test "destroying a link decrements the country book_count" do
      country = Books::Country.create!(name: "Bolivian")
      book = Books::Book.create!(title: "Counter Cache Decrement Probe")
      link = Books::BookCountry.create!(book: book, country: country)

      assert_difference -> { country.reload.book_count }, -1 do
        link.destroy!
      end
    end

    test "the same book and country cannot be linked twice" do
      book = Books::Book.create!(title: "Duplicate Link Probe")
      country = Books::Country.create!(name: "Chilean")
      Books::BookCountry.create!(book: book, country: country)

      assert_raises ActiveRecord::RecordNotUnique do
        Books::BookCountry.create!(book: book, country: country)
      end
    end

    test "destroying a country destroys its links" do
      country = Books::Country.create!(name: "Ecuadorian")
      book = Books::Book.create!(title: "Dependent Destroy Probe")
      Books::BookCountry.create!(book: book, country: country)

      assert_difference -> { Books::BookCountry.count }, -1 do
        country.destroy!
      end
    end
  end
end
