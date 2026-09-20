# frozen_string_literal: true

# The shared skeleton of every CSV export action (spec §9). Included by a
# controller that defines `export`; never by an action that is edge-cached.
#
#   include CsvExportable
#   def export ... send_on_demand_ranked_items(...) / serve_prebuilt_or_prepare(...)
#
# Filters run in declaration order: prevent_caching and require_signed_in!
# come from this concern's `included` block, so they run before the
# controller's own before_actions (which load and gate the configuration).
# rate_limit is declared after require_signed_in! so an anonymous caller is
# turned away before `by:` runs, otherwise every anonymous request would share
# one nil bucket.
#
# Those two are lambdas, not symbols, on purpose: a later
# `before_action :require_signed_in!, only: [...]` in the including controller
# REPLACES an earlier symbol callback of the same name (CallbackChain#append_one
# drops duplicates by filter), which silently un-gated the saved-search export
# once SavedSearchesController declared its own. A lambda never matches as a
# duplicate, so the gate holds whatever the controller declares.
module CsvExportable
  extend ActiveSupport::Concern

  REFRESH_SECONDS = 15

  included do
    before_action -> { prevent_caching }, only: [:export]
    before_action -> { response.headers["X-Robots-Tag"] = "noindex" }, only: [:export]
    before_action -> { require_signed_in! }, only: [:export]
    rate_limit to: 20, within: 1.hour,
      by: -> { current_user&.id },
      with: -> { head :too_many_requests },
      store: Rails.application.config.x.rate_limit_store,
      # scope: one bucket per user across every export controller, not 20/h per domain.
      scope: :csv_export,
      only: [:export]
  end

  private

  def export_limit
    ::CsvExports::Limits.limit_for(current_user)
  end

  def send_csv(data, filename:)
    send_data data, type: "text/csv; charset=utf-8", filename: filename, disposition: "attachment"
  end

  # The member + unfiltered case: serve the pre-built file (any attached file
  # is a good one -- Generate attaches only on success -- so this holds during
  # a regeneration and after a failed one), or claim a generate and show the
  # preparing page. The HTTP Refresh header re-requests this URL; once the
  # file exists the response is an attachment and the browser downloads it
  # without leaving the page. Not a flash: the cached rankings page skips the
  # session, so a flash set here would never render.
  def serve_prebuilt_or_prepare(ranking_configuration)
    export = ranking_configuration.csv_export
    if export&.downloadable?
      # Blob#download returns ASCII-8BIT; the bytes are UTF-8 (the header says so),
      # and labelling them keeps response.body comparable to the on-demand path.
      send_csv export.file.download.force_encoding(Encoding::UTF_8), filename: export.file.filename.to_s
    else
      Services::CsvExports::RequestGenerate.call(ranking_configuration: ranking_configuration)
      response.headers["Refresh"] = REFRESH_SECONDS.to_s
      @csv_export_back_path = csv_export_back_path
      render "csv_exports/preparing", status: :accepted, formats: [:html], content_type: "text/html"
    end
  end

  # Where the preparing page sends someone back to. The including controller
  # overrides this with its rankings page; the view falls back to "/".
  # Not request.referer: after a Refresh-triggered reload the referer is the
  # export URL itself.
  def csv_export_back_path = nil

  def send_on_demand_ranked_items(relation, row_class:, filename:)
    io = StringIO.new
    ::CsvExports::RankedItems.call(relation: relation, row_class: row_class, limit: export_limit, io: io)
    send_csv io.string, filename: filename
  end

  # The music/games shape: the registry's unfiltered relation, optionally
  # narrowed by the page's year filter, sent on demand under the viewer's cap.
  def send_year_filtered_export(ranking_configuration, year_filter:)
    entry = ::CsvExports::Registry.for_config(ranking_configuration)
    relation = entry.relation.call(ranking_configuration)
    if year_filter
      table = entry.media_table or raise ArgumentError, "#{entry.slug} has no media_table; year filters need one"
      relation = ::Services::RankedItemsFilterService.new(relation, table_name: table).apply_year_filter(year_filter)
    end
    send_on_demand_ranked_items(relation, row_class: entry.row_class,
      filename: ::CsvExports::Registry.filename_for(ranking_configuration))
  end
end
