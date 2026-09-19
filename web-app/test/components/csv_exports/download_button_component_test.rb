# frozen_string_literal: true

require "test_helper"

module CsvExports
  class DownloadButtonComponentTest < ViewComponent::TestCase
    test "a capped button carries the controller, the link and the explanation dialog" do
      render_inline(DownloadButtonComponent.new(export_path: "/export.csv?category_id=novels", noun: "books"))

      assert_selector "[data-controller='csv-export'][data-csv-export-modal-value='csv_export_modal'].tooltip[data-tip='Download CSV']"
      assert_selector "a[href='/export.csv?category_id=novels'][rel='nofollow'][data-action='csv-export#download'][data-turbo='false'][data-testid='download-csv'][aria-label='Download CSV'] svg"
      assert_selector "dialog#csv_export_modal.modal" do
        assert_selector "h3", text: /500 books/
        assert_selector "a.btn-primary[href='/export.csv?category_id=novels'][rel='nofollow'][data-turbo='false']", text: "Download top 500"
        assert_selector "a[href='/membership']", text: "Become a member"
        assert_selector "form[method='dialog'] button", text: "Cancel"
      end
    end

    test "an uncapped button is a plain link with no controller and no dialog" do
      render_inline(DownloadButtonComponent.new(export_path: "/my/lists/1.csv", noun: "books", capped: false))

      assert_selector ".tooltip[data-tip='Download CSV'] a[href='/my/lists/1.csv'][data-turbo='false'][data-testid='download-csv'][aria-label='Download CSV'] svg"
      assert_no_selector "[data-controller='csv-export']"
      assert_no_selector "dialog"
    end

    test "the noun and testid are configurable" do
      render_inline(DownloadButtonComponent.new(export_path: "/searches/1/export.csv", noun: "results", testid: "export-search"))

      assert_selector "h3", text: /500 results/
      assert_selector "a[data-testid='export-search']"
    end
  end
end
