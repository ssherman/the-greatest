module Services
  module Lists
    module Audits
      class Release
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(audit:, user:, note: nil, admin: false)
          audit.with_lock do
            allowed = admin || audit.user_id == user.id
            unless audit.in_progress? && allowed
              next Result.new(success?: false, data: {conflict: true}, errors: ["Audit #{audit.id} cannot be released by you"])
            end

            audit.update!(
              status: :released, finished_at: Time.current,
              note: [audit.note.presence, note.presence].compact.join("\n").presence
            )
            Result.new(success?: true, data: {audit: audit}, errors: [])
          end
        end
      end
    end
  end
end
