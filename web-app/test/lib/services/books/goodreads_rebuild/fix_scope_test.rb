# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class FixScopeTest < ActiveSupport::TestCase
        def scope(ours, export, subtitle: nil, authors_agree: true, wrong_book: false, survey: true)
          book = ::Books::Book.new(title: ours, subtitle: subtitle)
          record = ::Books::RebuildBookSurvey.new(authors_agree: authors_agree, wrong_book: wrong_book) if survey
          FixScope.call(book: book, survey: record, payload: {"full_title" => export})
        end

        test "series noise only is none" do
          assert_equal :none, scope("Euthydemus", "Euthydemus (Hackett Classics)")
        end

        test "our long title against the export's shortened one is none" do
          assert_equal :none, scope("The Red Indians: An Episodic, Informal Collection of Tales", "The Red Indians (Semaphore)")
        end

        test "ours with the real subtitle against a shorter export is none" do
          assert_equal :none, scope("X", "X", subtitle: "real subtitle")
          assert_equal :none, scope("Destination", "Destination", subtitle: "Void")
        end

        test "an export that matches our title and subtitle is none" do
          assert_equal :none, scope("Destination", "Destination: Void", subtitle: "Void")
        end

        test "a subtitle our title lacks is title_only" do
          assert_equal :title_only, scope("Destination", "Destination: Void")
          assert_equal :title_only, scope("Everything Must Go",
            "Everything Must Go: The Stories We Tell About the End of the World")
        end

        test "a title that really differs is full" do
          assert_equal :full, scope("Ninguno de nosotros volverá", "Auschwitz and After")
        end

        test "a prefix must end at a word boundary" do
          assert_equal :full, scope("Art", "Artificial Intelligence")
        end

        test "authors that differ are full, however alike the titles" do
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", authors_agree: false)
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", authors_agree: nil)
          assert_equal :full, scope("Euthydemus", "Euthydemus (Hackett Classics)", wrong_book: true)
        end

        test "no survey is full" do
          assert_equal :full, scope("Euthydemus", "Euthydemus", survey: false)
        end
      end
    end
  end
end
