# frozen_string_literal: true

require File.expand_path('../test_helper', __FILE__)
require 'beaneater/weighted_reserver'

describe Beaneater::WeightedReserver do
  describe "#reserve" do
    before do
      @beanstalk = Beaneater.new('localhost')
      @reserver = Beaneater::WeightedReserver.new(@beanstalk, "wt_high" => 4, "wt_low" => 1)
    end

    it "should reserve a job from a weighted tube" do
      @beanstalk.tubes.find('wt_high').put 'high job'

      job = @reserver.reserve
      assert_equal 'high job', job.body
      job.delete
    end

    it "should yield job to block" do
      @beanstalk.tubes.find('wt_high').put 'block job'

      yielded_job = nil
      @reserver.reserve { |j| yielded_job = j }
      assert_equal 'block job', yielded_job.body
      yielded_job.delete
    end

    it "should reserve from lower-weight tube when it has work" do
      @beanstalk.tubes.find('wt_low').put 'low job'

      job = @reserver.reserve
      assert_equal 'low job', job.body
      job.delete
    end

    it "should distribute jobs approximately according to weights" do
      # With weights wt_high:4, wt_low:1, expect ~80% high, ~20% low
      50.times { @beanstalk.tubes.find('wt_high').put 'high' }
      50.times { @beanstalk.tubes.find('wt_low').put 'low' }

      counts = { 'wt_high' => 0, 'wt_low' => 0 }
      50.times do
        job = @reserver.reserve
        counts[job.tube] += 1
        job.delete
      end

      # Allow some variance — weighted random, not deterministic
      # Expected: ~40 high, ~10 low. Allow generous bounds.
      assert counts['wt_high'] > 25, "Expected wt_high > 25, got #{counts['wt_high']}"
      assert counts['wt_low'] > 2, "Expected wt_low > 2, got #{counts['wt_low']}"
      assert counts['wt_high'] > counts['wt_low'], "Expected wt_high > wt_low"
    end

    it "should raise TimedOutError with timeout when all tubes empty" do
      assert_raises(Beaneater::TimedOutError) do
        @reserver.reserve(0)
      end
    end

    it "should accept timeout parameter" do
      @beanstalk.tubes.find('wt_high').put 'timed job'

      job = @reserver.reserve(1)
      assert_equal 'timed job', job.body
      job.delete
    end
  end

  describe "initialization" do
    it "should raise ArgumentError for empty weights" do
      assert_raises(ArgumentError) { Beaneater::WeightedReserver.new(stub, {}) }
    end

    it "should convert symbol keys to strings" do
      reserver = Beaneater::WeightedReserver.new(stub, high: 4, low: 1)
      assert_equal({ "high" => 4, "low" => 1 }, reserver.weights)
    end

    it "should raise ArgumentError for zero weight" do
      err = assert_raises(ArgumentError) { Beaneater::WeightedReserver.new(stub, "a" => 0, "b" => 2) }
      assert_match(/weight for 'a'/, err.message)
    end

    it "should raise ArgumentError for negative weight" do
      err = assert_raises(ArgumentError) { Beaneater::WeightedReserver.new(stub, "a" => -1) }
      assert_match(/positive integer/, err.message)
    end

    it "should raise ArgumentError for float weight" do
      err = assert_raises(ArgumentError) { Beaneater::WeightedReserver.new(stub, "a" => 1.5) }
      assert_match(/positive integer/, err.message)
    end
  end
end
