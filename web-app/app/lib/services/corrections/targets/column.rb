module Services
  module Corrections
    module Targets
      # A plain column on the record itself.
      class Column
        def self.read(record, field_name)
          record.public_send(field_name)
        end

        # Assigns without saving. The applier writes every accepted column and then
        # issues one save!, so a validation failure rolls back the whole correction
        # rather than leaving half of it applied.
        def self.write(record, field_name, value)
          record.public_send(:"#{field_name}=", value)
        end

        # A column can legitimately be cleared -- blanking a subtitle or a page
        # range is a real correction, and the write actually takes effect. See
        # PrimaryDescription#accepts_blank? for the target where it does not.
        def self.accepts_blank?
          true
        end
      end
    end
  end
end
