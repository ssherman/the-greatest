# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Starts a member import: validates the upload, saves it on the private
      # service with a queued import, and queues the run once that commits.
      class StartImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        IN_PROGRESS = "You already have an import running. You can upload another when it finishes."

        def self.call(user:, upload:)
          new(user: user, upload: upload).call
        end

        def initialize(user:, upload:)
          @user = user
          @upload = upload
        end

        def call
          validated = ValidateUpload.call(user: @user, upload: @upload)
          return Result.new(success?: false, data: {}, errors: validated.errors) unless validated.success?

          import = ActiveRecord::Base.transaction do
            @user.goodreads_imports.create!(source: :member, status: :queued).tap do |created|
              created.file.attach(io: StringIO.new(validated.data[:bytes]), filename: validated.data[:filename],
                content_type: "text/csv", identify: false)
            end
          end
          ::Books::Goodreads::RunImportJob.perform_async(import.id)
          Result.new(success?: true, data: {import: import}, errors: [])
        rescue ActiveRecord::RecordNotUnique
          Result.new(success?: false, data: {}, errors: [IN_PROGRESS])
        end
      end
    end
  end
end
