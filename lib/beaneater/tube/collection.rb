# frozen_string_literal: true

class Beaneater
  # Represents collection of tube related commands.

  class Tubes
    include Enumerable

    # @!attribute client
    #   @return [Beaneater] returns the client instance
    attr_reader :client

    # Creates new tubes instance.
    #
    # @param [Beaneater] client The beaneater client instance.
    # @example
    #  Beaneater::Tubes.new(@client)
    #
    def initialize(client)
      @client = client
    end

    def last_used
      client.connection.tube_used
    end

    def last_used=(tube_name)
      client.connection.tube_used = tube_name
    end

    # Delegates transmit to the connection object.
    #
    # @see Beaneater::Connection#transmit
    def transmit(command, **options)
      client.connection.transmit(command, **options)
    end

    # Finds the specified beanstalk tube.
    #
    # @param [String] tube_name Name of the beanstalkd tube
    # @return [Beaneater::Tube] specified tube
    # @example
    #   @pool.tubes.find('tube2')
    #   @pool.tubes['tube2']
    #     # => <Beaneater::Tube name="tube2">
    #
    # @api public
    def find(tube_name)
      Tube.new(client, tube_name)
    end
    alias_method :[], :find

    # Reserves a ready job looking at all watched tubes.
    #
    # @param [Integer] timeout Number of seconds before timing out.
    # @param [Proc] block Callback to perform on the reserved job.
    # @yield [job] Reserved beaneater job.
    # @return [Beaneater::Job] Reserved beaneater job.
    # @example
    #   @client.tubes.reserve { |job| process(job) }
    #     # => <Beaneater::Job id=5 body="foo">
    #
    # @api public
    def reserve(timeout=nil, &block)
      res = transmit(
        timeout ? "reserve-with-timeout #{timeout}" : 'reserve')
      job = Job.new(client, res)
      block.call(job) if block_given?
      job
    end

    # Reserves a batch of ready jobs from watched tubes.
    #
    # @param [Integer] count Maximum number of jobs to reserve
    # @return [Array<Beaneater::Job>] Array of reserved jobs
    # @raise [Beaneater::TimedOutError] No jobs available within timeout
    # @example
    #   @client.tubes.reserve_batch(10)
    #     # => [<Beaneater::Job id=1 body="foo">, ...]
    #
    # @api public
    def reserve_batch(count)
      results = client.connection.reserve_batch(count)
      results.map { |res| Job.new(client, res) }
    end

    # Sets the reserve mode for the connection.
    #
    # @param [String, Symbol] mode The reserve mode ('weighted' or 'fifo')
    # @return [Hash] Response from beanstalkd
    # @example
    #   @client.tubes.reserve_mode(:weighted)
    #   @client.tubes.reserve_mode(:fifo)
    #
    # @api public
    def reserve_mode(mode)
      transmit("reserve-mode #{mode}")
    end

    # Reserves a specific job by its ID.
    #
    # @param [Integer, String] id The job ID to reserve
    # @return [Beaneater::Job, nil] The reserved job, or nil if not found
    # @example
    #   @client.tubes.reserve_job(123)
    #     # => <Beaneater::Job id=123 body="foo">
    #
    # @api public
    def reserve_job(id)
      res = transmit("reserve-job #{id}")
      Job.new(client, res)
    rescue Beaneater::NotFoundError
      nil
    end

    # Returns stats for a job group.
    #
    # @param [String] group The group name
    # @return [Beaneater::StatStruct] Struct of group stats
    # @example
    #   @client.tubes.stats_group('batch-1')
    #     # => #<StatStruct name="batch-1" pending=5 ...>
    #
    # @api public
    def stats_group(group)
      res = transmit("stats-group #{group}")
      StatStruct.from_hash(res[:body])
    end

    # List of all known beanstalk tubes.
    #
    # @return [Array<Beaneater::Tube>] List of all beanstalk tubes.
    # @example
    #   @client.tubes.all
    #     # => [<Beaneater::Tube name="tube2">, <Beaneater::Tube name="tube3">]
    #
    # @api public
    def all
      transmit('list-tubes')[:body].map do |tube_name|
        Tube.new(client, tube_name)
      end
    end

    # Calls the given block once for each known beanstalk tube, passing that element as a parameter.
    #
    # @return An Enumerator is returned if no block is given.
    # @example
    #   @pool.tubes.each {|t| puts t.name}
    #
    # @api public
    def each(&block)
      all.each(&block)
    end

    # List of watched beanstalk tubes.
    #
    # @return [Array<Beaneater::Tube>] List of watched beanstalk tubes.
    # @example
    #   @client.tubes.watched
    #     # => [<Beaneater::Tube name="tube2">, <Beaneater::Tube name="tube3">]
    #
    # @api public
    def watched
      last_watched = transmit('list-tubes-watched')[:body]
      client.connection.tubes_watched = last_watched.dup
      last_watched.map do |tube_name|
        Tube.new(client, tube_name)
      end
    end

    # Currently used beanstalk tube.
    #
    # @return [Beaneater::Tube] Currently used beanstalk tube.
    # @example
    #   @client.tubes.used
    #     # => <Beaneater::Tube name="tube2">
    #
    # @api public
    def used
      last_used = transmit('list-tube-used')[:id]
      Tube.new(client, last_used)
    end

    # Add specified beanstalkd tubes as watched.
    #
    # @param [*String] names Name of tubes to watch
    # @raise [Beaneater::InvalidTubeName] Tube to watch was invalid.
    # @example
    #   @client.tubes.watch('foo', 'bar')
    #
    # @api public
    def watch(*names, weight: nil)
      names.each do |t|
        cmd = weight ? "watch #{t} #{weight}" : "watch #{t}"
        transmit cmd
        client.connection.add_to_watched(t)
      end
    rescue BadFormatError => ex
      raise InvalidTubeName, "Tube in '#{ex.cmd}' is invalid!"
    end

    # Add specified beanstalkd tubes as watched and ignores all other tubes.
    #
    # @param [*String] names Name of tubes to watch
    # @raise [Beaneater::InvalidTubeName] Tube to watch was invalid.
    # @example
    #   @client.tubes.watch!('foo', 'bar')
    #
    # @api public
    def watch!(*names)
      old_tubes = watched.map(&:name) - names.map(&:to_s)
      watch(*names)
      ignore(*old_tubes)
    end

    # Ignores specified beanstalkd tubes.
    #
    # @param [*String] names Name of tubes to ignore
    # @example
    #   @client.tubes.ignore('foo', 'bar')
    #
    # @api public
    def ignore(*names)
      names.each do |w|
        transmit "ignore #{w}"
        client.connection.remove_from_watched(w)
      end
    end

    # Set specified tube as used.
    #
    # @param [String] tube Tube to be used.
    # @example
    #  @conn.tubes.use("some-tube")
    #
    def use(tube)
      return tube if last_used == tube
      transmit("use #{tube}")
      self.last_used = tube
    rescue BadFormatError
      raise InvalidTubeName, "Tube cannot be named '#{tube}'"
    end
  end # Tubes
end # Beaneater
