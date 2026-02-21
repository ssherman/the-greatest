# frozen_string_literal: true

# Music base class for wizard import jobs.
# Inherits shared import logic from BaseWizardImportJob.
#
# Music-specific subclasses (Songs, Albums) inherit from this class.
#
class Music::BaseWizardImportJob < ::BaseWizardImportJob
end
