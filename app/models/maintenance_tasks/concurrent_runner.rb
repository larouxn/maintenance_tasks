# frozen_string_literal: true

module MaintenanceTasks
  # This class is responsible for coordinating concurrent execution of maintenance tasks.
  # It creates multiple child runs that process different partitions of the data in parallel.
  class ConcurrentRunner
    class << self
      # Runs a Task concurrently by creating multiple child runs.
      #
      # @param name [String] the name of the Task to be run.
      # @param concurrency_level [Integer] the number of parallel jobs to run.
      # @param csv_file [attachable, nil] a CSV file that provides the collection.
      # @param arguments [Hash] the arguments to persist to the Run.
      # @param run_model [Class] the Run model class to use.
      # @param metadata [Hash] additional metadata for the run.
      #
      # @return [Run] the parent run that coordinates the concurrent execution.
      #
      # @raise [UnsupportedConcurrencyError] if the task doesn't support concurrency.
      # @raise [ActiveRecord::RecordInvalid] if validation errors occur.
      def run_concurrent(name:, concurrency_level:, csv_file: nil, arguments: {}, run_model: Run, metadata: nil)
        task = Task.named(name)

        # Validate that the task supports concurrency
        validate_task_supports_concurrency!(task, csv_file)

        # Create the parent run
        parent_run = run_model.new(
          task_name: name,
          arguments: arguments,
          metadata: metadata,
          concurrency_level: concurrency_level,
          status: :enqueued,
        )

        if csv_file
          parent_run.csv_file.attach(csv_file)
          parent_run.csv_file.filename = filename(name)
        end

        parent_run.save!

        # Calculate partitions and create child runs
        partitions = calculate_partitions(task, concurrency_level)

        partitions.each_with_index do |partition, index|
          create_child_run(parent_run, partition, index)
        end

        # Start monitoring job for parent run
        monitor_job = MonitorConcurrentTaskJob.new(parent_run)
        parent_run.job_id = monitor_job.job_id
        parent_run.save!

        unless monitor_job.enqueue
          raise UnsupportedConcurrencyError, "Failed to enqueue monitoring job"
        end

        parent_run
      end

      private

      def validate_task_supports_concurrency!(task, csv_file)
        # CSV collections are not supported for concurrency yet
        if csv_file.present? || task.has_csv_content?
          raise UnsupportedConcurrencyError, "CSV collections are not yet supported for concurrent execution"
        end

        # Only ActiveRecord collections are currently supported
        unless supports_active_record_collection?(task)
          raise UnsupportedConcurrencyError, "Concurrency is only supported for ActiveRecord collections"
        end
      end

      def supports_active_record_collection?(task)
        collection = task.new.collection
        collection.is_a?(ActiveRecord::Relation) ||
          collection.is_a?(ActiveRecord::Batches::BatchEnumerator)
      end

      def calculate_partitions(task, concurrency_level)
        task_instance = task.new
        collection = task_instance.collection

        # Handle batch enumerator
        if collection.is_a?(ActiveRecord::Batches::BatchEnumerator)
          collection = collection.relation
        end

        # Get the total count and primary key range
        total_count = collection.count
        return [] if total_count == 0

        # Get primary key column (usually 'id')
        primary_key = collection.klass.primary_key
        min_id = collection.minimum(primary_key) || 0
        max_id = collection.maximum(primary_key) || 0

        # Calculate partition size
        partition_size = (total_count.to_f / concurrency_level).ceil

        # Create partitions based on ID ranges
        partitions = []
        concurrency_level.times do |i|
          start_offset = i * partition_size
          end_offset = [(i + 1) * partition_size - 1, total_count - 1].min

          # Calculate actual ID boundaries by using LIMIT and OFFSET
          start_id = if start_offset == 0
            min_id
          else
            collection.order(primary_key).offset(start_offset).limit(1).pluck(primary_key).first || max_id
          end

          end_id = if end_offset >= total_count - 1
            max_id
          else
            collection.order(primary_key).offset(end_offset).limit(1).pluck(primary_key).first || max_id
          end

          # Skip empty partitions
          next if start_id > end_id

          partitions << {
            cursor: start_id,
            end_cursor: end_id,
            estimated_count: [partition_size, total_count - start_offset].min,
          }
        end

        partitions
      end

      def create_child_run(parent_run, partition, index)
        child_run = parent_run.class.new(
          task_name: parent_run.task_name,
          arguments: parent_run.arguments,
          metadata: parent_run.metadata,
          parent_run_id: parent_run.id,
          partition_index: index,
          cursor: partition[:cursor],
          end_cursor: partition[:end_cursor],
          tick_total: partition[:estimated_count],
          status: :enqueued,
        )

        # Create and enqueue the job for this partition
        job = instantiate_job(child_run)
        child_run.job_id = job.job_id
        child_run.save!

        enqueue_job(child_run, job)
      end

      def enqueue_job(run, job)
        unless job.enqueue
          raise "The job to perform #{run.task_name} could not be enqueued. " \
            "Enqueuing has been prevented by a callback."
        end
      rescue => error
        run.persist_error(error)
        raise Runner::EnqueuingError, run
      end

      def filename(task_name)
        formatted_task_name = task_name.underscore.gsub("/", "_")
        "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}_#{formatted_task_name}.csv"
      end

      def instantiate_job(run)
        MaintenanceTasks.job.constantize.new(run)
      end
    end
  end
end
