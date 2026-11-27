# frozen_string_literal: true

# A books list's audit history on its admin page: what each audit decided and
# what it changed. Books only; the caller decides whether to render it.
class Admin::Lists::AuditsComponent < ViewComponent::Base
  def initialize(list:, can_release:)
    @list = list
    @can_release = can_release
  end

  private

  attr_reader :list, :can_release

  def audits
    @audits ||= list.list_audits.includes(:user).order(started_at: :desc).to_a
  end

  def field_changes(audit)
    (audit.field_changes || {}).fetch("fields", {})
  end

  def penalties(audit, key)
    Array((audit.field_changes || {})[key])
  end

  def item_rows(audit, key)
    Array((audit.field_changes || {})[key])
  end

  def pending_submissions(audit)
    Array((audit.field_changes || {})["pending_submissions"])
  end

  def row_label(row)
    "row #{row["id"]}, book #{row["book_id"]}, position #{row["position"]}"
  end

  def item_change_label(row)
    parts = %w[book_id position].filter_map { |key| "#{key} #{row[key]["from"]} -> #{row[key]["to"]}" if row[key] }
    "row #{row["id"]}: #{parts.join(", ")}"
  end

  def changed?(audit)
    field_changes(audit).any? || penalties(audit, "penalties_attached").any? || penalties(audit, "penalties_detached").any? ||
      %w[items_added items_removed items_changed].any? { |key| item_rows(audit, key).any? }
  end

  def verdict_badge_class(audit)
    audit.verified? ? "badge-success" : "badge-warning"
  end

  def format_time(time)
    time&.strftime("%b %d, %Y %H:%M")
  end

  def user_label(audit)
    audit.user&.email || "unknown user"
  end
end
