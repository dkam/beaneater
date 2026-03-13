# frozen_string_literal: true

# test/tubes_test.rb

require File.expand_path('../test_helper', __FILE__)

describe Beaneater::Tubes do
  describe "for #find" do
    before do
      @beanstalk  = stub
      @tubes = Beaneater::Tubes.new(@beanstalk)
    end

    it("should return Tube obj") { assert_kind_of Beaneater::Tube, @tubes.find(:foo) }
    it("should return Tube name") { assert_equal "foo", @tubes.find(:foo).name }
    it("should support hash syntax") { assert_equal "bar", @tubes["bar"].name }
  end # find

  describe "for #use" do
    before do
      @beanstalk = Beaneater.new('localhost')
    end

    it "should switch to used tube for valid name" do
      Beaneater::Tube.new(@beanstalk, 'some_name')
      @beanstalk.tubes.use('some_name')
      assert_equal 'some_name', @beanstalk.tubes.used.name
    end

    it "should raise for invalid tube name" do
      assert_raises(Beaneater::InvalidTubeName) { @beanstalk.tubes.use('; ') }
    end
  end # use

  describe "for #watch & #watched" do
    before do
      @beanstalk = Beaneater.new('localhost')
    end

    it 'should watch specified tubes' do
      @beanstalk.tubes.watch('foo')
      @beanstalk.tubes.watch('bar')
      assert_equal ['default', 'foo', 'bar'].sort, @beanstalk.tubes.watched.map(&:name).sort
    end

    it 'should raise invalid name for bad tube' do
      assert_raises(Beaneater::InvalidTubeName) { @beanstalk.tubes.watch('; ') }
    end
  end # watch! & watched

  describe "for #all" do
    before do
      @beanstalk = Beaneater.new('localhost')
      @beanstalk.tubes.find('foo').put 'bar'
      @beanstalk.tubes.find('bar').put 'foo'
    end

    it 'should retrieve all tubes' do
      ['default', 'foo', 'bar'].each do |t|
        assert @beanstalk.tubes.all.map(&:name).include?(t)
      end
    end
  end # all

  describe "for Enumerable" do
    before do
      @beanstalk = Beaneater.new('localhost')
      @beanstalk.tubes.find('foo').put 'bar'
      @beanstalk.tubes.find('bar').put 'foo'
    end

    it 'should map tubes' do
      ['default', 'foo', 'bar'].each do |t|
        assert @beanstalk.tubes.map(&:name).include?(t)
      end
    end
  end

  describe "for #used" do
    before do
      @beanstalk = Beaneater.new('localhost')
      @beanstalk.tubes.find('foo').put 'bar'
      @beanstalk.tubes.find('bar').put 'foo'
    end

    it 'should retrieve used tube' do
      assert_equal 'bar', @beanstalk.tubes.used.name
    end

    it 'should support dashed tubes' do
      @beanstalk.tubes.find('der-bam').put 'foo'
      assert_equal 'der-bam', @beanstalk.tubes.used.name
    end
  end # used

  describe "for #watch!" do
    before do
      @beanstalk = Beaneater.new('localhost')
    end

    it 'should watch specified tubes' do
      @beanstalk.tubes.watch!(:foo)
      @beanstalk.tubes.watch!('bar')
      assert_equal ['bar'].sort, @beanstalk.tubes.watched.map(&:name).sort
    end
  end # watch!

  describe "for #ignore" do
    before do
      @beanstalk = Beaneater.new('localhost')
    end

    it 'should ignore specified tubes' do
      @beanstalk.tubes.watch('foo')
      @beanstalk.tubes.watch('bar')
      @beanstalk.tubes.ignore('foo')
      assert_equal ['default', 'bar'].sort, @beanstalk.tubes.watched.map(&:name).sort
    end
  end # ignore

  describe "for #watch with weight" do
    before do
      @beanstalk = stub
      @connection = stub(tubes_watched: ['default'])
      @beanstalk.stubs(:connection).returns(@connection)
      @tubes = Beaneater::Tubes.new(@beanstalk)
    end

    it 'should send watch command with weight' do
      @connection.expects(:transmit).with("watch foo 4").returns({status: "WATCHING", id: "2"})
      @connection.expects(:add_to_watched).with("foo")
      @tubes.watch('foo', weight: 4)
    end

    it 'should send watch command without weight by default' do
      @connection.expects(:transmit).with("watch foo").returns({status: "WATCHING", id: "2"})
      @connection.expects(:add_to_watched).with("foo")
      @tubes.watch('foo')
    end
  end # watch with weight

  describe "for #reserve_mode" do
    before do
      @beanstalk = stub
      @connection = stub
      @beanstalk.stubs(:connection).returns(@connection)
      @tubes = Beaneater::Tubes.new(@beanstalk)
    end

    it 'should send reserve-mode weighted command' do
      @connection.expects(:transmit).with("reserve-mode weighted").returns({status: "USING", id: "weighted"})
      @tubes.reserve_mode(:weighted)
    end

    it 'should send reserve-mode fifo command' do
      @connection.expects(:transmit).with("reserve-mode fifo").returns({status: "USING", id: "fifo"})
      @tubes.reserve_mode(:fifo)
    end
  end # reserve_mode

  describe "for #reserve" do
    before do
      @beanstalk  = Beaneater.new('localhost')
      @tube  = @beanstalk.tubes.find 'tube'
      @time = Time.now.to_i
      @tube.put "foo reserve #{@time}"
    end

    it("should reserve job") do
      @beanstalk.tubes.watch 'tube'
      job = @beanstalk.tubes.reserve
      assert_equal "foo reserve #{@time}", job.body
      job.delete
    end

    it("should reserve job with block") do
      @beanstalk.tubes.watch 'tube'
      job = nil
      @beanstalk.tubes.reserve { |j| job = j; job.delete }
      assert_equal "foo reserve #{@time}", job.body
    end

    it("should reserve job with block and timeout") do
      @beanstalk.tubes.watch 'tube'
      job = nil
      @beanstalk.tubes.reserve(0)  { |j| job = j; job.delete }
      assert_equal "foo reserve #{@time}", job.body
    end

    it "should raise TimedOutError with timeout" do
      @beanstalk.tubes.watch 'tube'
      @beanstalk.tubes.reserve(0)  { |j| job = j; job.delete }
      assert_raises(Beaneater::TimedOutError) { @beanstalk.tubes.reserve(0) }
    end

    it "should raise DeadlineSoonError with ttr 1" do
      @tube.reserve.delete
      @tube.put "foo reserve #{@time}", :ttr => 1
      @beanstalk.tubes.watch 'tube'
      @beanstalk.tubes.reserve
      assert_raises(Beaneater::DeadlineSoonError) { @beanstalk.tubes.reserve(0) }
    end

  end # reserve

  describe "for #reserve_batch" do
    before do
      @beanstalk = Beaneater.new('localhost')
      @tube = @beanstalk.tubes.find 'batch_tube'
    end

    it "should raise TimedOutError on empty queue with timeout" do
      @beanstalk.tubes.watch! 'batch_tube'
      assert_raises(Beaneater::TimedOutError) { @beanstalk.tubes.reserve_batch(5, timeout: 0) }
    end

    it "should reserve 1 job" do
      @tube.put "batch job 1"
      @beanstalk.tubes.watch! 'batch_tube'
      jobs = @beanstalk.tubes.reserve_batch(1, timeout: 0)
      assert_equal 1, jobs.size
      assert_kind_of Beaneater::Job, jobs.first
      assert_equal "batch job 1", jobs.first.body
      jobs.each(&:delete)
    end

    it "should reserve N jobs" do
      3.times { |i| @tube.put "batch job #{i}" }
      @beanstalk.tubes.watch! 'batch_tube'
      jobs = @beanstalk.tubes.reserve_batch(3, timeout: 0)
      assert_equal 3, jobs.size
      jobs.each do |job|
        assert_kind_of Beaneater::Job, job
        job.delete
      end
    end

    it "should return partial results when fewer available than requested" do
      2.times { |i| @tube.put "partial job #{i}" }
      @beanstalk.tubes.watch! 'batch_tube'
      jobs = @beanstalk.tubes.reserve_batch(10, timeout: 0)
      assert_equal 2, jobs.size
      jobs.each(&:delete)
    end

    it "should return deletable jobs" do
      @tube.put "deletable job"
      @beanstalk.tubes.watch! 'batch_tube'
      jobs = @beanstalk.tubes.reserve_batch(1, timeout: 0)
      assert_equal 1, jobs.size
      jobs.first.delete
      assert_raises(Beaneater::NotFoundError) { jobs.first.stats }
    end
  end # reserve_batch
end # Beaneater::Tubes
