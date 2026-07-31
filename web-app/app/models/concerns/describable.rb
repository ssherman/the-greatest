module Describable
  extend ActiveSupport::Concern

  included do
    has_many :descriptions, -> { order(:id) }, as: :describable, dependent: :destroy, autosave: true
  end

  def primary_description(kind: :summary, locale: "en")
    Descriptions::Resolver.call(descriptions, kind: kind, locale: locale)
  end

  # Assigns without saving, so an importer can call this on a record that is not
  # persisted yet and let the parent's save cascade. Looks the row up with detect
  # rather than find_or_initialize_by: the latter queries and returns an instance
  # that is not in the association target, which autosave never sees, so the write
  # is silently lost. Never assigns rank (D5).
  def assign_description(source:, content:, kind: :summary, locale: "en", **attrs)
    return nil if content.blank?

    row = descriptions.detect { |d| d.kind == kind.to_s && d.locale == locale && d.source == source.to_s } ||
      descriptions.build(kind: kind, locale: locale, source: source)
    row.assign_attributes(content: content, retrieved_at: Time.current, **attrs)
    row
  end
end
