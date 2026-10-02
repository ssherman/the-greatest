# frozen_string_literal: true

# "Download CSV" (spec §11): a quiet ghost icon button (lucide download) with
# a "Download CSV" tooltip, meant for the far right of a page's toolbar row.
# On an edge-cached page the HTML is the same for everyone, so the top-500
# explanation is a static dialog that csv_export_controller.js opens for a
# signed-in non-member. The <a href> is real: with JS off the link still works
# and the server applies the cap. The dialog explains; it never enforces.
#
# capped: false (user lists) renders the same icon as a bare link -- no
# controller, no dialog. The component renders its own dialog, so it is
# rendered once per page.
module CsvExports
  class DownloadButtonComponent < ViewComponent::Base
    MODAL_ID = "csv_export_modal"

    def initialize(export_path:, noun:, capped: true, testid: "download-csv")
      @export_path = export_path
      @noun = noun
      @capped = capped
      @testid = testid
    end

    private

    attr_reader :export_path, :noun, :testid

    def capped?
      @capped
    end

    def modal_id
      MODAL_ID
    end

    def preview_rows
      ::CsvExports::Limits::PREVIEW_ROWS
    end
  end
end
