# frozen_string_literal: true

class Books::Goodreads::RunImportJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: false

  def perform(import_id)
  end
end
