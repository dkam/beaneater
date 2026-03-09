# frozen_string_literal: true

class Beaneater
  # Provides weighted tube selection for reserving jobs.
  #
  # Instead of beanstalkd's default behaviour of returning the earliest
  # ready job across all watched tubes, this class selects a tube based
  # on weighted probability before reserving, so higher-weighted tubes
  # are serviced proportionally more often.
  #
  # When all tubes are empty, falls back to a blocking reserve on all
  # tubes — no busy-polling.
  #
  # @example
  #   client = Beaneater.new('localhost')
  #   reserver = Beaneater::WeightedReserver.new(client, "high" => 4, "medium" => 2, "low" => 1)
  #   loop { reserver.reserve { |job| process(job) } }
  #
  class WeightedReserver
    attr_reader :client, :weights

    # @param client [Beaneater] A beaneater client instance
    # @param weights [Hash{String => Integer}] Tube names mapped to their weights
    def initialize(client, weights)
      raise ArgumentError, "weights must be a non-empty Hash" unless weights.is_a?(Hash) && !weights.empty?

      @client = client
      @weights = weights.transform_keys(&:to_s)
      validate_weights!(@weights)
    end

    # Reserve a job using weighted random tube selection.
    #
    # Picks tubes randomly with probability proportional to their weights.
    # If the selected tube is empty, it's removed from candidates and another
    # is picked. When all tubes are empty, falls back to a blocking reserve
    # on all tubes.
    #
    # @param [Integer] timeout Number of seconds before timing out on the
    #   fallback reserve. nil blocks forever, matching Tubes#reserve behaviour.
    # @yield [job] Optional block called with the reserved job
    # @return [Beaneater::Job] Reserved beaneater job
    def reserve(timeout = nil, &block)
      candidates = @weights.dup

      while candidates.any?
        tube = weighted_select(candidates)
        client.tubes.watch!(tube)
        begin
          job = client.tubes.reserve(0)
          block.call(job) if block
          return job
        rescue Beaneater::TimedOutError
          candidates.delete(tube)
        end
      end

      # All tubes empty — block on all tubes until a job arrives
      client.tubes.watch!(*@weights.keys)
      job = client.tubes.reserve(timeout)
      block.call(job) if block
      job
    end

    private

    def validate_weights!(weights)
      weights.each do |name, weight|
        unless weight.is_a?(Integer) && weight > 0
          raise ArgumentError, "weight for '#{name}' must be a positive integer, got #{weight.inspect}"
        end
      end
    end

    def weighted_select(weights)
      total = weights.values.sum
      r = rand(total)
      weights.each do |tube, weight|
        r -= weight
        return tube if r < 0
      end
      weights.keys.last
    end
  end
end
