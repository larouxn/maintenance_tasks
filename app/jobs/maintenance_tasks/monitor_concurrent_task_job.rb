# frozen_string_literal: true

module MaintenanceTasks
  # Job that monitors concurrent task execution by periodically checking
  # the status of child runs and updating the parent run accordingly.
  class MonitorConcurrentTaskJob < ActiveJob::Base
    # How often to check child run status (in seconds)
    MONITORING_INTERVAL = 5.seconds

    # Monitors the progress of concurrent child runs and updates the parent run status.
    #
    # @param parent_run [MaintenanceTasks::Run] the parent run to monitor
    def perform(parent_run)
      @parent_run = parent_run
      @parent_run.running! unless @parent_run.running?

      monitor_child_runs
    end

    private

    def monitor_child_runs
      loop do
        @parent_run.reload

        # Stop monitoring if parent run is stopping
        break if @parent_run.stopping?

        child_runs = @parent_run.child_runs.reload

        # Check if all child runs are completed
        if all_child_runs_completed?(child_runs)
          complete_parent_run(child_runs)
          break
        end

        # Check if any child run failed
        if any_child_run_failed?(child_runs)
          fail_parent_run(child_runs)
          break
        end

        # Update parent run progress
        update_parent_progress(child_runs)

        # Wait before next check
        sleep(MONITORING_INTERVAL)
      end
    end

    def all_child_runs_completed?(child_runs)
      child_runs.all?(&:completed?)
    end

    def any_child_run_failed?(child_runs)
      child_runs.any? { |run| run.status.in?(["errored", "cancelled"]) }
    end

    def complete_parent_run(child_runs)
      # Aggregate final statistics
      total_tick_count = child_runs.sum(&:tick_count)
      total_time_running = child_runs.maximum(:time_running) || 0

      @parent_run.update!(
        status: :succeeded,
        tick_count: total_tick_count,
        time_running: total_time_running,
        ended_at: Time.now,
      )

      # Run completion callbacks
      run_task_callbacks(:complete)
    end

    def fail_parent_run(child_runs)
      failed_run = child_runs.find { |run| run.status.in?(["errored", "cancelled"]) }

      # TODO: do we really need to manually move to cancelling then cancelled?
      # Can we just call parent_run.cancel! or something?
      if failed_run.errored?
        @parent_run.update!(
          status: :errored,
          error_class: failed_run.error_class,
          error_message: failed_run.error_message,
          backtrace: failed_run.backtrace,
          ended_at: Time.now,
        )
      elsif failed_run.cancelled?
        # First transition to cancelling, then to cancelled
        @parent_run.update!(status: :cancelling) unless @parent_run.cancelling?
        @parent_run.update!(
          status: :cancelled,
          ended_at: Time.now,
        )
      end

      # TODO: same here as above, can we just do child_run.cancel! ???
      # Cancel remaining child runs via proper state transitions
      child_runs.each do |run|
        next unless run.active?

        # First transition to cancelling, then to cancelled
        run.update!(status: :cancelling) unless run.cancelling?
        run.update!(status: :cancelled)
      end

      # Run error callbacks
      run_task_callbacks(:error)
    end

    def update_parent_progress(child_runs)
      total_tick_count = child_runs.sum(&:tick_count)
      total_time_running = child_runs.maximum(:time_running) || 0

      @parent_run.update_columns(
        tick_count: total_tick_count,
        time_running: total_time_running,
        updated_at: Time.now,
      )
    end

    def run_task_callbacks(callback_type)
      task = @parent_run.task
      task.run_callbacks(callback_type)
    rescue => error
      Rails.logger.error("Error running #{callback_type} callbacks: #{error.message}")
    end
  end
end
