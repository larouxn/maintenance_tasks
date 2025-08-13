# frozen_string_literal: true

require "test_helper"

module MaintenanceTasks
  class MonitorConcurrentTaskJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @parent_run = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        concurrency_level: 2,
        status: :enqueued,
      )

      @child_run_1 = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        parent_run: @parent_run,
        partition_index: 0,
        tick_count: 10,
        time_running: 5.0,
        status: :enqueued,
      )

      @child_run_2 = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        parent_run: @parent_run,
        partition_index: 1,
        tick_count: 15,
        time_running: 8.0,
        status: :enqueued,
      )

      @job = MonitorConcurrentTaskJob.new
    end

    test "job inherits from ActiveJob::Base" do
      assert MonitorConcurrentTaskJob < ActiveJob::Base
    end

    test "MONITORING_INTERVAL is defined" do
      assert_equal 5.seconds, MonitorConcurrentTaskJob::MONITORING_INTERVAL
    end

    test "sets parent run to running if not already running" do
      @parent_run.update!(status: :enqueued)

      # Override the monitor loop to avoid infinite loop in tests
      @job.define_singleton_method(:monitor_child_runs) {}
      @job.perform(@parent_run)

      assert_predicate @parent_run.reload, :running?
    end

    test "does not change status if parent run is already running" do
      @parent_run.update!(status: :running)

      @job.define_singleton_method(:monitor_child_runs) {}
      @job.perform(@parent_run)

      assert_predicate @parent_run.reload, :running?
    end

    test "all_child_runs_completed? returns true when all children are completed" do
      @child_run_1.running!
      @child_run_1.succeeded!
      @child_run_2.running!
      @child_run_2.succeeded!

      assert @job.send(:all_child_runs_completed?, [@child_run_1, @child_run_2])
    end

    test "all_child_runs_completed? returns false when any child is not completed" do
      @child_run_1.running!
      @child_run_1.succeeded!
      @child_run_2.running!

      refute @job.send(:all_child_runs_completed?, [@child_run_1, @child_run_2])
    end

    test "any_child_run_failed? returns true when any child errored" do
      @child_run_1.running!
      @child_run_2.running!
      @child_run_2.errored!

      assert @job.send(:any_child_run_failed?, [@child_run_1, @child_run_2])
    end

    test "any_child_run_failed? returns true when any child cancelled via cancelling" do
      @child_run_1.running!
      @child_run_2.running!
      @child_run_2.cancelling!
      @child_run_2.cancelled!

      assert @job.send(:any_child_run_failed?, [@child_run_1, @child_run_2])
    end

    test "any_child_run_failed? returns false when no child failed" do
      @child_run_1.running!
      @child_run_2.running!
      @child_run_2.succeeded!

      refute @job.send(:any_child_run_failed?, [@child_run_1, @child_run_2])
    end

    test "complete_parent_run aggregates statistics and marks as succeeded" do
      freeze_time do
        # First transition parent to running (status transition requirement)
        @parent_run.running!

        # Properly transition child runs: enqueued -> running -> succeeded
        @child_run_1.running!
        @child_run_1.update!(status: :succeeded, tick_count: 20, time_running: 10.0)
        @child_run_2.running!
        @child_run_2.update!(status: :succeeded, tick_count: 30, time_running: 15.0)

        # Set up instance variable for the job
        @job.instance_variable_set(:@parent_run, @parent_run)

        # Mock the callback method to avoid Task instantiation issues
        @job.define_singleton_method(:run_task_callbacks) { |type| }

        @job.send(:complete_parent_run, [@child_run_1, @child_run_2])

        @parent_run.reload
        assert_predicate @parent_run, :succeeded?
        assert_equal 50, @parent_run.tick_count # 20 + 30
        assert_equal 15.0, @parent_run.time_running # max(10.0, 15.0)
        assert_equal Time.now, @parent_run.ended_at
      end
    end

    test "fail_parent_run copies error details from failed child and cancels others" do
      freeze_time do
        @parent_run.running!
        @child_run_1.running!
        @child_run_2.running!
        @child_run_2.update!(
          status: :errored,
          error_class: "StandardError",
          error_message: "Test error",
          backtrace: ["line 1", "line 2"],
        )

        @job.instance_variable_set(:@parent_run, @parent_run)
        @job.define_singleton_method(:run_task_callbacks) { |type| }

        @job.send(:fail_parent_run, [@child_run_1, @child_run_2])

        @parent_run.reload
        assert_predicate @parent_run, :errored?
        assert_equal "StandardError", @parent_run.error_class
        assert_equal "Test error", @parent_run.error_message
        assert_equal ["line 1", "line 2"], @parent_run.backtrace
        assert_equal Time.now, @parent_run.ended_at

        # Check that active child run was cancelled via proper state transitions
        assert_predicate @child_run_1.reload, :cancelled?
      end
    end

    test "fail_parent_run handles cancelled child run" do
      freeze_time do
        @parent_run.running!
        @child_run_1.running!
        @child_run_2.running!
        @child_run_2.cancelling!
        @child_run_2.cancelled!

        @job.instance_variable_set(:@parent_run, @parent_run)
        @job.define_singleton_method(:run_task_callbacks) { |type| }

        @job.send(:fail_parent_run, [@child_run_1, @child_run_2])

        @parent_run.reload
        assert_predicate @parent_run, :cancelled?
        assert_equal Time.now, @parent_run.ended_at

        # Check that active child run was cancelled via proper state transitions
        assert_predicate @child_run_1.reload, :cancelled?
      end
    end

    test "update_parent_progress aggregates tick count and max time" do
      @child_run_1.update!(tick_count: 25, time_running: 12.0)
      @child_run_2.update!(tick_count: 35, time_running: 8.0)

      @job.instance_variable_set(:@parent_run, @parent_run)

      freeze_time do
        @job.send(:update_parent_progress, [@child_run_1, @child_run_2])

        @parent_run.reload
        assert_equal 60, @parent_run.tick_count # 25 + 35
        assert_equal 12.0, @parent_run.time_running # max(12.0, 8.0)
        assert_equal Time.now, @parent_run.updated_at
      end
    end

    test "update_parent_progress handles children with zero time_running" do
      @child_run_1.update!(tick_count: 25, time_running: 0.0)
      @child_run_2.update!(tick_count: 35, time_running: 10.0)

      @job.instance_variable_set(:@parent_run, @parent_run)

      @job.send(:update_parent_progress, [@child_run_1, @child_run_2])

      @parent_run.reload
      assert_equal 60, @parent_run.tick_count
      assert_equal 10.0, @parent_run.time_running
    end

    test "run_task_callbacks handles callback errors gracefully" do
      # Setup a run with a task that will cause an error
      task = mock("task")
      task.expects(:run_callbacks).with(:complete).raises(StandardError.new("Callback error"))
      @parent_run.stubs(:task).returns(task)

      @job.instance_variable_set(:@parent_run, @parent_run)

      Rails.logger.expects(:error).with("Error running complete callbacks: Callback error")

      assert_nothing_raised do
        @job.send(:run_task_callbacks, :complete)
      end
    end
  end
end
