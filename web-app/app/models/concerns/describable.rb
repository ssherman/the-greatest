module Describable
  extend ActiveSupport::Concern

  included do
    has_many :descriptions, as: :describable, dependent: :destroy
  end

  def primary_description(kind: :summary, locale: "en")
    Descriptions::Resolver.call(descriptions, kind: kind, locale: locale)
  end
end
