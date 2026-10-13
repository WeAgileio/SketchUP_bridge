require 'json'
require 'securerandom'
require 'digest'

module CodexSketchupBridge
  class BridgeError < StandardError
    attr_reader :code
    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  module Protocol
    VERSION = 1
    ID = /\A[a-zA-Z0-9_-]{1,80}\z/
    MAX_BYTES = 1_048_576
    module_function

    def timestamp
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')
    end

    def valid_timestamp?(value)
      match = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/.match(value)
      return false unless match
      year, month, day, hour, minute, second = match.captures.take(6).map(&:to_i)
      leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
      return false unless (1..12).cover?(month) && (1..days[month-1]).cover?(day) && hour < 24 && minute < 60 && second < 60
      zone = match[7]
      zone == 'Z' || (zone[1,2].to_i < 24 && zone[4,2].to_i < 60)
    end

    def fail!(code, message)
      raise BridgeError.new(code, message)
    end

    def json_value!(value, depth = 0)
      fail!('invalid_result', 'JSON nesting exceeds 64') if depth > 64
      case value
      when Hash
        fail!('invalid_result', 'Object keys must be strings') unless value.keys.all? { |k| k.is_a?(String) }
        value.each_value { |v| json_value!(v, depth + 1) }
      when Array
        value.each { |v| json_value!(v, depth + 1) }
      when Float
        fail!('invalid_result', 'Numbers must be finite') unless value.finite?
      when String, Integer, TrueClass, FalseClass, NilClass
      else
        fail!('invalid_result', "Unsupported JSON value: #{value.class}")
      end
      value
    end

    def validate!(request)
      fail!('invalid_request', 'Request must be an object') unless request.is_a?(Hash)
      fail!('invalid_request', 'Invalid request_id') unless request['request_id'].is_a?(String) && ID.match?(request['request_id'])
      fail!('unsupported_version', 'Expected protocol_version 1') unless request['protocol_version'] == VERSION
      %w[session_id model_token action submitted_at].each do |key|
        fail!('invalid_request', "#{key} must be a nonempty string") unless request[key].is_a?(String) && !request[key].empty?
      end
      fail!('invalid_request', 'expected_revision must be a nonnegative integer') unless request['expected_revision'].is_a?(Integer) && request['expected_revision'] >= 0
      fail!('invalid_request', 'arguments must be an object') unless request['arguments'].is_a?(Hash)
      fail!('invalid_request', 'submitted_at must be a valid ISO 8601 timestamp') unless valid_timestamp?(request['submitted_at'])
      json_value!(request)
      request
    rescue ArgumentError
      fail!('invalid_request', 'submitted_at must be ISO 8601')
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |k, h| h[k] = canonical(value[k]) }
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def fingerprint(request)
      # A re-submission timestamp is not a change to the operation.
      Digest::SHA256.hexdigest(JSON.generate(canonical(request.reject { |k, _| k == 'submitted_at' })))
    end
  end
end
