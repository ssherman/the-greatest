# Service for managing identifiers across all media domains
# Provides CRUD operations and lookup methods for external identifiers
class IdentifierService
  # Result object for service responses
  Result = Struct.new(:success?, :data, :errors, keyword_init: true)

  # Add an identifier to an object
  # @param identifiable [ActiveRecord::Base] The object to add identifier to
  # @param type [Symbol|String] The identifier type (enum value)
  # @param value [String] The identifier value
  # @return [Result] Success/failure with identifier or errors
  def self.add_identifier(identifiable, type, value)
    identifier = Identifier.new(
      identifiable: identifiable,
      identifier_type: type,
      value: value.to_s.strip
    )

    if identifier.save
      Result.new(success?: true, data: identifier, errors: [])
    else
      Result.new(success?: false, data: nil, errors: identifier.errors.full_messages)
    end
  rescue ArgumentError => e
    Result.new(success?: false, data: nil, errors: [e.message])
  end

  # Find an object by its identifier
  # @param type [Symbol|String] The identifier type
  # @param value [String] The identifier value
  # @return [ActiveRecord::Base|nil] The found object or nil
  def self.find_by_identifier(type, value)
    type = type.to_s if type.is_a?(Symbol)
    identifier = Identifier.find_by(identifier_type: type, value: value.to_s.strip)
    identifier&.identifiable
  end

  # Find an object by identifier within a specific domain
  # @param identifiable_type [String] The class name (e.g., 'Music::Artist')
  # @param type [Symbol|String] The identifier type
  # @param value [String] The identifier value
  # @return [ActiveRecord::Base|nil] The found object or nil
  def self.find_by_identifier_in_domain(identifiable_type, type, value)
    type = type.to_s if type.is_a?(Symbol)
    identifier = Identifier.find_by(
      identifiable_type: identifiable_type,
      identifier_type: type,
      value: value.to_s.strip
    )
    identifier&.identifiable
  end

  # Find an object by value only within a domain (for ISBN/EAN use case)
  # @param identifiable_type [String] The class name (e.g., 'Books::Book')
  # @param value [String] The identifier value
  # @return [ActiveRecord::Base|nil] The found object or nil
  def self.find_by_value_in_domain(identifiable_type, value)
    identifier = Identifier.find_by(
      identifiable_type: identifiable_type,
      value: value.to_s.strip
    )
    identifier&.identifiable
  end

  # Get all identifiers for an object
  # @param identifiable [ActiveRecord::Base] The object to get identifiers for
  # @return [ActiveRecord::Relation] Collection of identifiers
  def self.resolve_identifiers(identifiable)
    Identifier.where(identifiable: identifiable).order(:identifier_type)
  end

  # Check if an identifier exists
  # @param type [Symbol|String] The identifier type
  # @param value [String] The identifier value
  # @return [Boolean] True if identifier exists
  def self.identifier_exists?(type, value)
    type = type.to_s if type.is_a?(Symbol)
    Identifier.exists?(identifier_type: type, value: value.to_s.strip)
  end
end
