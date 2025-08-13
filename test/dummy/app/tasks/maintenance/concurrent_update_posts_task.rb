# frozen_string_literal: true

module Maintenance
  class ConcurrentUpdatePostsTask < MaintenanceTasks::Task
    # Enable concurrent execution with 4 parallel jobs
    concurrent 4

    def collection
      Post.all
    end

    def process(post)
      # Simulate some work that benefits from parallelization
      # For example, calling an external API
      sleep(0.1)

      post.update!(content: "Updated concurrently on #{Time.now.utc}")
    end
  end
end
