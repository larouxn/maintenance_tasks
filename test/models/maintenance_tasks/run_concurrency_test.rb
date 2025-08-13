# frozen_string_literal: true

require "test_helper"

module MaintenanceTasks
  class RunConcurrencyTest < ActiveSupport::TestCase
    test "parent_run? returns true for parent runs" do
      run = Run.new(parent_run_id: nil, concurrency_level: 4)
      assert run.parent_run?
    end

    test "child_run? returns true for child runs" do
      parent_run = Run.create!(task_name: "Maintenance::UpdatePostsTask", status: :enqueued)
      child_run = Run.new(parent_run_id: parent_run.id)
      assert child_run.child_run?
    end

    test "concurrent? returns true for concurrent runs" do
      parent_run = Run.new(parent_run_id: nil, concurrency_level: 4)
      assert parent_run.concurrent?

      child_run = Run.new(parent_run_id: 1)
      assert child_run.concurrent?
    end

    test "aggregate_progress returns sum of child runs for parent" do
      parent_run = Run.create!(task_name: "Maintenance::UpdatePostsTask", status: :enqueued, concurrency_level: 2)

      Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        status: :running,
        parent_run_id: parent_run.id,
        tick_count: 10,
      )
      Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        status: :running,
        parent_run_id: parent_run.id,
        tick_count: 20,
      )

      assert_equal 30, parent_run.aggregate_progress
    end

    test "aggregate_progress returns own tick_count for non-concurrent runs" do
      run = Run.create!(task_name: "Maintenance::UpdatePostsTask", status: :running, tick_count: 15)
      assert_equal 15, run.aggregate_progress
    end

    test "overall_status aggregates child run statuses correctly" do
      parent_run = Run.create!(task_name: "Maintenance::UpdatePostsTask", status: :enqueued, concurrency_level: 2)

      # Create child runs in enqueued state
      child1 = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        status: :enqueued,
        parent_run_id: parent_run.id,
      )
      child2 = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        status: :enqueued,
        parent_run_id: parent_run.id,
      )

      # Test running status
      child1.running!
      assert_equal :running, parent_run.overall_status

      # Test all succeeded - both children need to transition through running first
      child2.running!
      child1.succeeded!
      child2.succeeded!
      assert_equal :succeeded, parent_run.reload.overall_status

      # Test with errored child run - create a new run to avoid transition issues
      child3 = Run.create!(
        task_name: "Maintenance::UpdatePostsTask",
        status: :enqueued,
        parent_run_id: parent_run.id,
      )
      child3.running!
      child3.errored!
      assert_equal :errored, parent_run.reload.overall_status
    end
  end
end
