# frozen_string_literal: true

# Music base class for wizard parse jobs.
# Inherits shared parsing logic from BaseWizardParseListJob.
#
# Music-specific subclasses (Songs, Albums) inherit from this class.
#
class Music::BaseWizardParseListJob < ::BaseWizardParseListJob
end
