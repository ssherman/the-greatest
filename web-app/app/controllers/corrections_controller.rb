class CorrectionsController < ApplicationController
  include Cacheable
  include VisitorIp

  layout :domain_layout

  before_action :set_record, only: [:new]
  before_action :cache_for_show_page, only: [:new]

  def new
    # The books layout emits "noindex, follow" unless @indexable is truthy, so nil
    # would already do it. Explicit, because "not indexed" here is a decision, not
    # an accident of a default.
    @indexable = false
    @fields = @record.class.correctable_fields.values
  end

  private

  # correctable_type is a ROUTE DEFAULT here, not a param -- see config/routes.rb.
  # It still goes through the registry rather than constantize, so the two callers
  # (#new and #create) share one resolution path and neither can drift.
  def set_record
    @correctable_type = params[:correctable_type]
    klass = Services::Corrections::TypeRegistry.resolve(@correctable_type)
    raise ActionController::BadRequest, "Unknown correctable type" if klass.nil?

    @record = klass.find_by!(slug: params[:slug])
  end

  def domain_layout
    "#{Current.domain}/application"
  end
end
