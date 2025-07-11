# frozen_string_literal: true

module MaintenanceTasks
  # Extensions to RunsController for concurrent task support
  module ConcurrentRunsControllerConcern
    extend ActiveSupport::Concern
    
    private
    
    # Override pause to handle concurrent tasks
    def pause_run
      if @run.parent_run?
        # Pause all child runs
        @run.child_runs.where(status: [:enqueued, :running]).each(&:pause)
        @run.pause
      else
        @run.pause
      end
    end
    
    # Override cancel to handle concurrent tasks  
    def cancel_run
      if @run.parent_run?
        # Cancel all child runs
        @run.child_runs.where.not(status: Run::COMPLETED_STATUSES).each(&:cancel)
        @run.cancel
      else
        @run.cancel
      end
    end
    
    # Check if run can be resumed (for concurrent tasks, check if any child runs are paused)
    def can_resume_run?
      if @run.parent_run?
        @run.child_runs.paused.any?
      else
        @run.paused?
      end
    end
  end
end
