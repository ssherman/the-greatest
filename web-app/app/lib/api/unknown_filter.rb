# frozen_string_literal: true

module Api
  # A well-formed category_id or country_id slug that names nothing. Answered as
  # 404 not_found with a detail naming the parameter and the slug.
  #
  # Deliberately a plain StandardError, not an ActiveRecord::RecordNotFound: the
  # generic RecordNotFound handler would flatten it into "No book at that address".
  class UnknownFilter < StandardError
    attr_reader :param, :slug

    def initialize(param, slug)
      @param = param
      @slug = slug
      super(%(No #{param} matches "#{slug}"))
    end
  end
end
