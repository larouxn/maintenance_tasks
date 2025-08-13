# frozen_string_literal: true

require "test_helper"

module MaintenanceTasks
  class ConcurrentRunnerTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @task_name = "Maintenance::ConcurrentUpdatePostsTask"
    end

    test "run_concurrent creates parent run with child runs" do
      # Create some test data with content
      3.times { |i| Post.create!(title: "Post #{i}", content: "Content #{i}") }

      parent_run = ConcurrentRunner.run_concurrent(
        name: @task_name,
        concurrency_level: 2,
      )

      assert parent_run.parent_run?
      assert_equal 2, parent_run.concurrency_level
      assert_equal @task_name, parent_run.task_name

      # Should create child runs
      assert_equal 2, parent_run.child_runs.count

      parent_run.child_runs.each_with_index do |child_run, index|
        assert child_run.child_run?
        assert_equal parent_run.id, child_run.parent_run_id
        assert_equal index, child_run.partition_index
        assert_not_nil child_run.cursor
        assert_not_nil child_run.end_cursor
        assert child_run.cursor <= child_run.end_cursor
      end
    end

    test "raises error for CSV collections as they're not supported" do
      error = assert_raises(MaintenanceTasks::UnsupportedConcurrencyError) do
        ConcurrentRunner.run_concurrent(
          name: "Maintenance::CsvCollectionTask",
          concurrency_level: 2,
        )
      end

      assert_includes(error.message, "Concurrency is only supported for ActiveRecord")
    end

    test "raises error for non-ActiveRecord collections as they're not supported" do
      error = assert_raises(MaintenanceTasks::UnsupportedConcurrencyError) do
        ConcurrentRunner.run_concurrent(
          name: "Maintenance::ArrayCollectionTask",
          concurrency_level: 2,
        )
      end

      assert_includes(error.message, "Concurrency is only supported for ActiveRecord")
    end
  end
end
