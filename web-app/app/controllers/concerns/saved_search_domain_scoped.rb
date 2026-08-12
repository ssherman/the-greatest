# frozen_string_literal: true

# Resolves the STI subclass serving the current domain, and 404s a host with
# none. SavedSearchesController and every JSON picker endpoint underneath
# saved_searches/ (categories, languages, countries) need both halves
# together. This was duplicated once already (categories, copying the
# original controller's private methods verbatim); adding two more endpoints
# in the same shape is the third and fourth copy, and the point at which to
# extract rather than paste again.
#
# Usage:
#   class MyController < ApplicationController
#     include SavedSearchDomainScoped
#     before_action :require_domain_support!
#   end
module SavedSearchDomainScoped
  extend ActiveSupport::Concern

  private

  def domain_class
    return @domain_class if defined?(@domain_class)

    @domain_class = SavedSearch.subclass_for(Current.domain)
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if domain_class.nil?
  end
end
