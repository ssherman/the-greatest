# frozen_string_literal: true

# The books list wizard (books list wizard spec): the shared core, mounted for
# books lists.
class Admin::Books::ListWizardController < Admin::Books::BaseController
  include ListWizardCore

  private

  def list_class = ::Books::List
end
