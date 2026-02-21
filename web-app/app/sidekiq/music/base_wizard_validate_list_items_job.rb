# frozen_string_literal: true

# Music base class for wizard validate jobs.
# Inherits shared validation logic from BaseWizardValidateListItemsJob.
#
# Music-specific subclasses (Songs, Albums) inherit from this class.
#
class Music::BaseWizardValidateListItemsJob < ::BaseWizardValidateListItemsJob
end
