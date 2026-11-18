# frozen_string_literal: true

require "test_helper"

module Books
  module PublisherIntake
    class HoldTest < ActiveSupport::TestCase
      def facts(**overrides)
        {
          title: "A Good Book",
          subtitle: nil,
          contributors: [{name: "Jane Author", role: "author"}],
          formats: [{isbn13: "9780316564861", format: "hardcover", format_label: "Hardcover"}],
          language: "en",
          series_name: nil
        }.merge(overrides)
      end

      def fmt(label, isbn: "9780316564861") = {isbn13: isbn, format_label: label}

      test "a complete English book is ready" do
        assert_equal [:ready, nil], Hold.call(facts)
      end

      test "missing title is incomplete" do
        assert_equal [:held, :incomplete], Hold.call(facts(title: ""))
      end

      test "no contributor or only blank names is incomplete" do
        assert_equal [:held, :incomplete], Hold.call(facts(contributors: []))
        assert_equal [:held, :incomplete], Hold.call(facts(contributors: [{name: " ", role: "author"}]))
      end

      test "no ISBN-13 on any format is incomplete" do
        assert_equal [:held, :incomplete], Hold.call(facts(formats: [fmt("Hardcover", isbn: nil)]))
        assert_equal [:held, :incomplete], Hold.call(facts(formats: []))
      end

      test "a stand-in title is a placeholder" do
        assert_equal [:held, :placeholder], Hold.call(facts(title: "Untitled Memoir"))
        assert_equal [:held, :placeholder], Hold.call(facts(title: "TBD"))
      end

      test "a lone stand-in contributor is a placeholder" do
        assert_equal [:held, :placeholder], Hold.call(facts(contributors: [{name: "To Be Confirmed", role: "author"}]))
      end

      test "a stand-in among real contributors is not a placeholder" do
        contributors = [{name: "TBC", role: "author"}, {name: "Jane Author", role: "author"}]

        assert_equal [:ready, nil], Hold.call(facts(contributors: contributors))
      end

      test "a language other than English is non_english" do
        assert_equal [:held, :non_english], Hold.call(facts(language: "es"))
      end

      test "en, eng, English and en-GB are English" do
        %w[en eng English EN en-GB].each { |code| assert_equal [:ready, nil], Hold.call(facts(language: code)), code }
      end

      test "an absent language is not held" do
        assert_equal [:ready, nil], Hold.call(facts(language: nil))
      end

      test "all formats being non-book products is not_a_book" do
        assert_equal [:held, :not_a_book], Hold.call(facts(formats: [fmt("Calendar")]))
      end

      test "one calendar format plus one hardcover is ready" do
        assert_equal [:ready, nil], Hold.call(facts(formats: [fmt("Calendar"), fmt("Hardcover", isbn: "9780802169990")]))
      end

      test "a box set format label is a set" do
        assert_equal [:held, :set], Hold.call(facts(formats: [fmt("Boxed Set")]))
        assert_equal [:held, :set], Hold.call(facts(formats: [fmt("Bundle")]))
      end

      test "A Collection of Essays is ready" do
        assert_equal [:ready, nil], Hold.call(facts(title: "A Collection of Essays"))
      end

      test "The Tolstoy Trilogy is ready" do
        assert_equal [:ready, nil], Hold.call(facts(title: "The Tolstoy Trilogy"))
      end

      test "The Complete Series Box Set is a set" do
        assert_equal [:held, :set], Hold.call(facts(title: "The Complete Series Box Set"))
      end

      test "Books 1-3 is a set" do
        assert_equal [:held, :set], Hold.call(facts(title: "Books 1-3"))
      end

      test "a #1-3 range in the title is a set" do
        assert_equal [:held, :set], Hold.call(facts(title: "Saga #1-3"))
      end

      test "a set word in the subtitle is a set" do
        assert_equal [:held, :set], Hold.call(facts(subtitle: "The Omnibus"))
      end

      test "a series name of Omnibus Editions with an ordinary title is ready" do
        assert_equal [:ready, nil], Hold.call(facts(series_name: "Omnibus Editions"))
      end

      test "incomplete wins over placeholder and non_english" do
        assert_equal [:held, :incomplete], Hold.call(facts(title: "TBD", language: "fr", contributors: []))
      end

      test "placeholder wins over non_english when nothing is missing" do
        assert_equal [:held, :placeholder], Hold.call(facts(title: "TBD", language: "fr"))
      end

      test "non_english wins over not_a_book and set" do
        assert_equal [:held, :non_english], Hold.call(facts(language: "fr", title: "Books 1-3", formats: [fmt("Calendar")]))
      end

      test "not_a_book wins over set" do
        assert_equal [:held, :not_a_book], Hold.call(facts(title: "Books 1-3", formats: [fmt("Puzzle")]))
      end
    end
  end
end
