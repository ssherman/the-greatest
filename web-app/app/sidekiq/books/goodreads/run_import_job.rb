# frozen_string_literal: true

# Runs one Goodreads import (Services::Books::GoodreadsImports::RunImport).
# The import keeps its state on its own row, so a failed run is retried by an
# admin, not by Sidekiq (spec §13).
class Books::Goodreads::RunImportJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: false

  def perform(import_id)
    import = ::Books::GoodreadsImport.find_by(id: import_id)
    return if import.nil?

    ::Services::Books::GoodreadsImports::RunImport.call(import: import)
  end
end
