# frozen_string_literal: true

module MaintenanceTasks
  # Handles coordination of concurrent task execution
  class ConcurrentRunner
    include ActiveSupport::Configurable
    
    # Exception raised when concurrency configuration is invalid
    class InvalidConcurrencyError < StandardError; end
    
    # Partitioning strategies for different collection types
    PARTITION_STRATEGIES = {
      id_range: IdRangePartitioner,
      cursor_based: CursorBasedPartitioner,
      custom: CustomPartitioner
    }.freeze
    
    def initialize(task_class, concurrency_config)
      @task_class = task_class
      @concurrency_config = concurrency_config
      validate_configuration!
    end
    
    # Creates parent run and spawns concurrent child runs
    def run(name:, csv_file: nil, arguments: {}, metadata: nil)
      parent_run = create_parent_run(name: name, arguments: arguments, metadata: metadata)
      
      begin
        partitions = create_partitions(parent_run)
        spawn_child_runs(parent_run, partitions, csv_file)
        parent_run.update!(
          status: :running,
          started_at: Time.now,
          tick_total: calculate_total_count(partitions)
        )
        
        parent_run
      rescue => error
        parent_run.persist_error(error)
        raise Runner::EnqueuingError, parent_run
      end
    end
    
    # Resume paused concurrent task
    def resume(parent_run)
      # Resume all paused child runs
      child_runs = parent_run.child_runs.paused
      child_runs.each do |child_run|
        Runner.resume(child_run)
      end
      
      parent_run.running!
    end
    
    private
    
    def create_parent_run(name:, arguments:, metadata:)
      Run.create!(
        task_name: name,
        arguments: arguments,
        metadata: metadata,
        is_parent_run: true,
        concurrency_level: @concurrency_config[:workers],
        status: :enqueued
      )
    end
    
    def create_partitions(parent_run)
      task = parent_run.task
      collection = task.collection
      strategy_class = PARTITION_STRATEGIES[@concurrency_config[:partition_strategy]]
      
      partitioner = strategy_class.new(
        collection: collection,
        workers: @concurrency_config[:workers],
        task: task
      )
      
      partitioner.create_partitions
    end
    
    def spawn_child_runs(parent_run, partitions, csv_file)
      partitions.map do |partition|
        child_run = Run.create!(
          task_name: parent_run.task_name,
          arguments: parent_run.arguments,
          metadata: parent_run.metadata,
          parent_run_id: parent_run.id,
          partition_start: partition[:start],
          partition_end: partition[:end],
          status: :enqueued
        )
        
        # Attach CSV file to child runs if needed
        if csv_file && parent_run.task.has_csv_content?
          child_run.csv_file.attach(csv_file)
        end
        
        # Enqueue child run job
        job = MaintenanceTasks.job.constantize.new(child_run)
        child_run.job_id = job.job_id
        child_run.enqueued!
        job.enqueue
        
        child_run
      end
    end
    
    def calculate_total_count(partitions)
      partitions.sum { |partition| partition[:estimated_count] || 0 }
    end
    
    def validate_configuration!
      workers = @concurrency_config[:workers]
      strategy = @concurrency_config[:partition_strategy]
      
      unless workers.is_a?(Integer) && workers > 0 && workers <= 20
        raise InvalidConcurrencyError, "Workers must be between 1 and 20"
      end
      
      unless PARTITION_STRATEGIES.key?(strategy)
        raise InvalidConcurrencyError, "Invalid partition strategy: #{strategy}"
      end
    end
  end
end
