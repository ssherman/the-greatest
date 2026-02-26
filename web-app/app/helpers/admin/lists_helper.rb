module Admin::ListsHelper
  # Counts the number of items in a list's items_json field.
  # Handles Hash format (e.g., {"albums": [...]}), Array format, and JSON strings.
  #
  # @param items_json [Hash, Array, String, nil] The items_json field from a list
  # @return [Integer] The count of items
  def count_items_json(items_json)
    return 0 if items_json.blank?

    # If it's a string, try to parse it first
    if items_json.is_a?(String)
      begin
        items_json = JSON.parse(items_json)
      rescue JSON::ParserError
        return 0
      end
    end

    if items_json.is_a?(Hash)
      # For album lists: {"albums": [...]} or song lists: {"songs": [...]}
      # Find the first value that is an Array and return its length
      items_json.values.find { |v| v.is_a?(Array) }&.length || 0
    elsif items_json.is_a?(Array)
      items_json.length
    else
      0
    end
  end

  # Converts items_json to a pretty-printed string for editing in a textarea.
  # If items_json is already a string, returns it as-is.
  # If it's a Hash or Array, converts it to pretty JSON.
  #
  # @param items_json [Hash, Array, String, nil] The items_json field from a list
  # @return [String, nil] Pretty-printed JSON string or the original string
  def items_json_to_string(items_json)
    return nil if items_json.blank?

    if items_json.is_a?(Hash) || items_json.is_a?(Array)
      JSON.pretty_generate(items_json)
    else
      items_json
    end
  end
end
