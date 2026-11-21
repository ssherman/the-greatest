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

  def changed?(audit)
    field_changes(audit).any? || penalties(audit, "penalties_attached").any? || penalties(audit, "penalties_detached").any?
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
