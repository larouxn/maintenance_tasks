# frozen_string_literal: true

module MaintenanceTasks
  # Job concern for handling concurrent task execution
  module ConcurrentTaskJobConcern
    extend ActiveSupport::Concern
    
    included do
      # Override build_enumerator for concurrent tasks
      def build_enumerator(run, cursor:)
        @run = run
        @task = @run.task
        
        # If this is a child run, build enumerator for partition
        if @run.parent_run_id.present?
          build_partition_enumerator(cursor: cursor)
        else
          # Parent run - just monitor child runs
          build_monitoring_enumerator
        end
      end
      
      # Override each_iteration for concurrent tasks
      def each_iteration(input, run)
        if run.parent_run_id.present?
          # Child run - process normally
          super(input, run)
        else
          # Parent run - monitor child runs
          monitor_child_runs(input, run)
        end
      end
    end
    
    private
    
    def build_partition_enumerator(cursor:)
      cursor ||= @run.cursor
      self.cursor_position = cursor
      
      # Build enumerator based on partition bounds
      collection = @task.collection
      partition_start = @run.partition_start
      partition_end = @run.partition_end
      
      # Apply partition filtering to the collection
      partitioned_collection = apply_partition_filter(collection, partition_start, partition_end)
      
      # Use existing enumerator building logic with partitioned collection
      enumerator_builder = self.enumerator_builder
      
      case partitioned_collection
      when ActiveRecord::Relation
        options = { cursor: cursor, columns: @task.cursor_columns }
        options[:batch_size] = @task.active_record_enumerator_batch_size if @task.active_record_enumerator_batch_size
        @collection_enum = enumerator_builder.active_record_on_records(partitioned_collection, **options)
      when Array
        @collection_enum = enumerator_builder.build_array_enumerator(partitioned_collection, cursor: cursor&.to_i)
      else
        raise ArgumentError, "Unsupported collection type for concurrent execution: #{partitioned_collection.class}"
      end
      
      unless @collection_enum.is_a?(JobIteration.enumerator_builder::Wrapper)
        @collection_enum = enumerator_builder.wrap(enumerator_builder, @collection_enum)
      end
      
      throttle_enumerator(@collection_enum)
    end
    
    def build_monitoring_enumerator
      # Create a simple enumerator that yields child run IDs for monitoring
      child_run_ids = @run.child_runs.pluck(:id)
      enumerator_builder = self.enumerator_builder
      @collection_enum = enumerator_builder.build_array_enumerator(child_run_ids)
      @collection_enum = enumerator_builder.wrap(enumerator_builder, @collection_enum) unless @collection_enum.is_a?(JobIteration.enumerator_builder::Wrapper)
      @collection_enum
    end
    
    def apply_partition_filter(collection, partition_start, partition_end)
      return collection unless partition_start && partition_end
      
      case collection
      when ActiveRecord::Relation
        # Assume ID-based partitioning for now
        collection.where(id: partition_start.to_i..partition_end.to_i)
      when Array
        # For arrays, use index-based partitioning
        start_idx = partition_start.to_i
        end_idx = partition_end.to_i
        collection[start_idx..end_idx] || []
      else
        collection
      end
    end
    
    def monitor_child_runs(child_run_id, parent_run)
      # Load child run to ensure it exists and is accessible
      Run.find(child_run_id)
      
      # Update parent run progress based on child run progress
      update_parent_progress(parent_run)
      
      # Check if all child runs are complete
      if all_child_runs_complete?(parent_run)
        complete_parent_run(parent_run)
        throw(:abort, :skip_complete_callbacks)
      end
      
      # Check for errors in child runs
      handle_child_run_errors(parent_run)
    end
    
    def update_parent_progress(parent_run)
      child_runs = parent_run.child_runs.reload
      total_ticks = child_runs.sum(:tick_count)
      total_time = child_runs.sum(:time_running)
      
      parent_run.update_columns(
        tick_count: total_ticks,
        time_running: total_time
      )
    end
    
    def all_child_runs_complete?(parent_run)
      parent_run.child_runs.where.not(status: Run::COMPLETED_STATUSES).empty?
    end
    
    def complete_parent_run(parent_run)
      # Check if any child runs failed
      failed_children = parent_run.child_runs.where(status: [:errored, :cancelled])
      
      if failed_children.any?
        # Parent run should error if any child failed
        parent_run.update!(
          status: :errored,
          ended_at: Time.now,
          error_class: "ConcurrentTaskError",
          error_message: "One or more child runs failed"
        )
      else
        # All children succeeded
        parent_run.update!(
          status: :succeeded,
          ended_at: Time.now
        )
      end
    end
    
    def handle_child_run_errors(parent_run)
      errored_children = parent_run.child_runs.where(status: :errored)
      
      if errored_children.any? && should_fail_fast?
        # Cancel remaining child runs
        parent_run.child_runs.where(status: [:enqueued, :running]).each(&:cancel)
        
        # Fail parent run
        error = StandardError.new("Child run failed: #{errored_children.first.error_message}")
        parent_run.persist_error(error)
        throw(:abort, :skip_complete_callbacks)
      end
    end
    
    def should_fail_fast?
      # Could be configurable per task
      false
    end
  end
end
