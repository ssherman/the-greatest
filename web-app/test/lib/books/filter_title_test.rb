require "test_helper"

module Books
  class FilterTitleTest < ActiveSupport::TestCase
    def genre(name) = Books::Category.new(name: name, category_type: :genre)

    def subject(name) = Books::Category.new(name: name, category_type: :subject)

    def location(name) = Books::Category.new(name: name, category_type: :location)

    def country(name) = Books::Country.new(name: name)

    test "no filters" do
      assert_equal "The Greatest Books of All Time", Books::FilterTitle.call
    end

    test "country and genre, genre already plural so Books is suppressed" do
      title = Books::FilterTitle.call(categories: [genre("Novels")], countries: [country("French")])

      assert_equal "The Greatest French Novels of All Time", title
    end

    test "singular genre keeps the word Books" do
      title = Books::FilterTitle.call(categories: [genre("Horror")], countries: [country("Usa")])

      assert_equal "The Greatest Usa Horror Books of All Time", title
    end

    test "two genres are joined with and" do
      title = Books::FilterTitle.call(categories: [genre("Horror"), genre("Sci-Fi")])

      assert_equal "The Greatest Horror and Sci Fi Books of All Time", title
    end

    test "three genres use an oxford comma" do
      title = Books::FilterTitle.call(categories: [genre("Horror"), genre("Sci-Fi"), genre("Mystery")])

      assert_equal "The Greatest Horror, Sci Fi, and Mystery Books of All Time", title
    end

    test "two countries are joined with a comma" do
      title = Books::FilterTitle.call(countries: [country("French"), country("German")])

      assert_equal "The Greatest French, German Books of All Time", title
    end

    test "a single year" do
      title = Books::FilterTitle.call(year_start: "1984", year_end: "1984")

      assert_equal "The Greatest Books of 1984", title
    end

    test "a start year only" do
      title = Books::FilterTitle.call(categories: [genre("Horror")], countries: [country("Usa")], year_start: "2020")

      assert_equal "The Greatest Usa Horror Books Since 2020", title
    end

    test "a full range" do
      title = Books::FilterTitle.call(categories: [genre("Horror")], countries: [country("Usa")], year_start: "2020", year_end: "2023")

      assert_equal "The Greatest Usa Horror Books From 2020 to 2023", title
    end

    test "an end year only" do
      assert_equal "The Greatest Books To 1900", Books::FilterTitle.call(year_end: "1900")
    end

    test "a subject category reads as on" do
      assert_equal "The Greatest Books of All Time on Politics", Books::FilterTitle.call(categories: [subject("Politics")])
    end

    test "a location category reads as set in" do
      assert_equal "The Greatest Books of All Time Set in France", Books::FilterTitle.call(categories: [location("France")])
    end

    test "genre, subject and location combine in that order" do
      title = Books::FilterTitle.call(categories: [genre("Novels"), subject("Politics"), location("France")])

      assert_equal "The Greatest Novels of All Time on Politics Set in France", title
    end
  end
end
