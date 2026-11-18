# Books -> Publisher Intake: one row per source (design §9). Read-only.
class Admin::Books::PublisherIntakeController < Admin::Books::BaseController
  def index
    authorize ::Books::PublisherTitle
    @sources = Services::Books::PublisherIntake::Status.call.data[:sources]
  end
end
