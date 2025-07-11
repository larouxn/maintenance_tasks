# frozen_string_literal: true

module MaintenanceTasks
  # Enhanced TaskJob that includes concurrent execution support
  class ConcurrentTaskJob < TaskJob
    include ConcurrentTaskJobConcern
    
    # Alias methods to integrate concurrent concern
    alias_method :build_concurrent_enumerator, :build_enumerator
    alias_method :concurrent_each_iteration, :each_iteration
    
    def build_enumerator(run, cursor:)
      @run = arguments.first
      @task = @run.task
      
      if @run.concurrent?
        build_concurrent_enumerator(run, cursor: cursor)
      else
        super(run, cursor: cursor)
      end
    end
    
    def each_iteration(input, run)
      if @run.concurrent?
        concurrent_each_iteration(input, run)
      else
        super(input, run)
      end
    end
  end
end
