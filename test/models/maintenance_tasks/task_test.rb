# frozen_string_literal: true

require "test_helper"

module MaintenanceTasks
  class TaskTest < ActiveSupport::TestCase
    test ".load_all returns list of tasks that inherit from the Task superclass" do
      expected = [
        "Maintenance::BatchImportPostsTask",
        "Maintenance::CallbackTestTask",
        "Maintenance::CancelledEnqueueTask",
        "Maintenance::CustomEnumeratingTask",
        "Maintenance::EnqueueErrorTask",
        "Maintenance::ErrorTask",
        "Maintenance::ImportPostsTask",
        "Maintenance::ImportPostsWithEncodingTask",
        "Maintenance::ImportPostsWithOptionsTask",
        "Maintenance::Nested::NestedMore::NestedMoreTask",
        "Maintenance::Nested::NestedTask",
        "Maintenance::NoCollectionTask",
        "Maintenance::ParamsTask",
        "Maintenance::TestTask",
        "Maintenance::UpdatePostsInBatchesTask",
        "Maintenance::UpdatePostsModulePrependedTask",
        "Maintenance::UpdatePostsTask",
        "Maintenance::UpdatePostsThrottledTask",
      ]
      assert_equal expected,
        MaintenanceTasks::Task.load_all.map(&:name).sort
    end

    test ".available_tasks raises a deprecation warning before calling .load_all" do
      expected_warning =
        "MaintenanceTasks::Task.available_tasks is deprecated and will be " \
          "removed from maintenance-tasks 3.0.0. Use .load_all instead.\n"

      Warning.expects(:warn).with(expected_warning, category: :deprecated)
      Task.expects(:load_all)

      Task.available_tasks
    end

    test ".named returns the task based on its name" do
      expected_task = Maintenance::UpdatePostsTask
      assert_equal expected_task, Task.named("Maintenance::UpdatePostsTask")
    end

    test ".named raises Not Found Error if the task doesn't exist" do
      error = assert_raises(Task::NotFoundError) do
        Task.named("Maintenance::DoesNotExist")
      end
      assert error.message
        .start_with?("Task Maintenance::DoesNotExist not found.")
      assert_equal "Maintenance::DoesNotExist", error.name
    end

    test ".named raises Not Found Error if the name doesn't refer to a Task" do
      error = assert_raises(Task::NotFoundError) do
        Task.named("Array")
      end
      assert error.message.start_with?("Array is not a Task.")
      assert_equal "Array", error.name
    end

    test ".process calls #process" do
      item = mock
      Maintenance::TestTask.any_instance.expects(:process).with(item)
      Maintenance::TestTask.process(item)
    end

    test ".collection calls #collection" do
      assert_equal [1, 2], Maintenance::TestTask.collection
    end

    test ".count calls #count" do
      assert_equal :no_count, Maintenance::TestTask.count
    end

    test "#count is :no_count by default" do
      task = Task.new
      assert_equal(:no_count, task.count)
    end

    test "#collection raises NoMethodError" do
      error = assert_raises(NoMethodError) { Task.new.collection }
      message = "MaintenanceTasks::Task must implement `collection`."
      assert error.message.start_with?(message)
    end

    test "#process raises NoMethodError" do
      error = assert_raises(NoMethodError) { Task.new.process("an item") }
      message = "MaintenanceTasks::Task must implement `process`."
      assert error.message.start_with?(message)
    end

    test ".throttle_conditions inherits conditions from superclass" do
      assert_equal [], Maintenance::TestTask.throttle_conditions
    end

    test ".throttle_on registers throttle condition for Task" do
      throttle_condition = -> { true }

      Maintenance::TestTask.throttle_on(&throttle_condition)

      task_throttle_conditions = Maintenance::TestTask.throttle_conditions
      assert_equal(1, task_throttle_conditions.size)

      condition = task_throttle_conditions.first
      assert_equal(throttle_condition, condition[:throttle_on])
      assert_equal(30.seconds, condition[:backoff].call)
    ensure
      Maintenance::TestTask.throttle_conditions = []
    end

    test ".cursor_columns returns nil" do
      task = Task.new
      assert_nil task.cursor_columns
    end

    test ".status_reload_frequency defaults to global configuration" do
      task = Task.new
      assert_equal MaintenanceTasks.status_reload_frequency, task.status_reload_frequency
    end

    test ".status_reload_frequency uses task-level override when configured" do
      original_reload_frequency = Maintenance::TestTask.status_reload_frequency
      Maintenance::TestTask.reload_status_every(5.seconds)
      task = Maintenance::TestTask.new

      assert_equal(5.seconds, task.status_reload_frequency)
    ensure
      Maintenance::TestTask.status_reload_frequency = original_reload_frequency
    end

    test ".concurrent validates and sets concurrency_level" do
      original_concurrency_level = Maintenance::TestTask.concurrency_level

      # Default level
      Maintenance::TestTask.concurrent
      assert_equal(2, Maintenance::TestTask.concurrency_level)

      # Custom valid level
      Maintenance::TestTask.concurrent(4)
      assert_equal(4, Maintenance::TestTask.concurrency_level)

      # Maximum valid level
      Maintenance::TestTask.concurrent(8)
      assert_equal(8, Maintenance::TestTask.concurrency_level)
    ensure
      Maintenance::TestTask.concurrency_level = original_concurrency_level
    end

    test ".concurrent raises ArgumentError for invalid concurrency levels" do
      original_concurrency_level = Maintenance::TestTask.concurrency_level

      # Too low level
      error = assert_raises(ArgumentError) do
        Maintenance::TestTask.concurrent(1)
      end
      assert_equal("Concurrency level must be an integer between 2 and 8", error.message)

      # Too high level
      error = assert_raises(ArgumentError) do
        Maintenance::TestTask.concurrent(9)
      end
      assert_equal("Concurrency level must be an integer between 2 and 8", error.message)

      # Non-integer level
      error = assert_raises(ArgumentError) do
        Maintenance::TestTask.concurrent("4")
      end
      assert_equal("Concurrency level must be an integer between 2 and 8", error.message)

      # Float level
      error = assert_raises(ArgumentError) do
        Maintenance::TestTask.concurrent(3.5)
      end
      assert_equal("Concurrency level must be an integer between 2 and 8", error.message)
    ensure
      Maintenance::TestTask.concurrency_level = original_concurrency_level
    end

    test ".concurrent? returns true when concurrency_level is set and greater than 1" do
      original_concurrency_level = Maintenance::TestTask.concurrency_level

      # Default state - no concurrency
      Maintenance::TestTask.concurrency_level = nil
      refute_predicate(Maintenance::TestTask, :concurrent?)

      # Level 1 - not concurrent
      Maintenance::TestTask.concurrency_level = 1
      refute_predicate(Maintenance::TestTask, :concurrent?)

      # Level 2 - concurrent (default)
      Maintenance::TestTask.concurrency_level = 2
      assert_predicate(Maintenance::TestTask, :concurrent?)

      # Higher level - concurrent (custom)
      Maintenance::TestTask.concurrency_level = 4
      assert_predicate(Maintenance::TestTask, :concurrent?)
    ensure
      Maintenance::TestTask.concurrency_level = original_concurrency_level
    end

    test "#concurrent? delegates to class method" do
      original_concurrency_level = Maintenance::TestTask.concurrency_level
      task = Maintenance::TestTask.new

      Maintenance::TestTask.concurrency_level = nil
      refute_predicate(task, :concurrent?)

      Maintenance::TestTask.concurrency_level = 3
      assert_predicate(task, :concurrent?)
    ensure
      Maintenance::TestTask.concurrency_level = original_concurrency_level
    end

    test ".concurrency_level defaults to nil" do
      assert_nil(Task.concurrency_level)
    end

    test ".concurrency_level inherits value from superclass" do
      assert_nil(Maintenance::TestTask.concurrency_level)

      original_concurrency_level = Maintenance::TestTask.concurrency_level

      Maintenance::TestTask.concurrent(3)

      assert_equal(3, Maintenance::TestTask.concurrency_level)

      task = Maintenance::TestTask.new
      assert_equal(3, task.class.concurrency_level)
    ensure
      Maintenance::TestTask.concurrency_level = original_concurrency_level
    end
  end
end
