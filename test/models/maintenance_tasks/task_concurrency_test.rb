# frozen_string_literal: true

require "test_helper"

module MaintenanceTasks
  class TaskConcurrencyTest < ActiveSupport::TestCase
    test "concurrent class method sets concurrency_level" do
      task_class = Class.new(Task) do
        concurrent 4
      end

      assert_equal 4, task_class.concurrency_level
      assert task_class.concurrent?
    end

    test "concurrent method validates concurrency level" do
      task_class = Class.new(Task)

      error = assert_raises(ArgumentError) do
        task_class.concurrent(1)
      end
      assert_includes error.message, "must be an integer between 2 and 50"

      error = assert_raises(ArgumentError) do
        task_class.concurrent(51)
      end
      assert_includes error.message, "must be an integer between 2 and 50"

      error = assert_raises(ArgumentError) do
        task_class.concurrent("invalid")
      end
      assert_includes error.message, "must be an integer between 2 and 50"
    end

    test "concurrent? returns false for non-concurrent tasks" do
      task_class = Class.new(Task)

      assert_not task_class.concurrent?
      assert_not task_class.new.concurrent?
    end

    test "concurrent? returns true for concurrent tasks" do
      task_class = Class.new(Task) do
        concurrent 3
      end

      assert task_class.concurrent?
      assert task_class.new.concurrent?
    end
  end
end
