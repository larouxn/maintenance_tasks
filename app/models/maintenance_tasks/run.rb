# frozen_string_literal: true

module MaintenanceTasks
  # Model that persists information related to a task being run from the UI.
  #
  # @api private
  class Run < ApplicationRecord
    # Various statuses a run can be in.
    STATUSES = [
      :enqueued,    # The task has been enqueued by the user.
      :running,     # The task is being performed by a job worker.
      :succeeded,   # The task finished without error.
      :cancelling,  # The task has been told to cancel but is finishing work.
      :cancelled,   # The user explicitly halted the task's execution.
      :interrupted, # The task was interrupted by the job infrastructure.
      :pausing,     # The task has been told to pause but is finishing work.
      :paused,      # The task was paused in the middle of the run by the user.
      :errored,     # The task code produced an unhandled exception.
    ]

    ACTIVE_STATUSES = [
      :enqueued,
      :running,
      :paused,
      :pausing,
      :cancelling,
      :interrupted,
    ]
    STOPPING_STATUSES = [
      :pausing,
      :cancelling,
      :cancelled,
    ]
    COMPLETED_STATUSES = [:succeeded, :errored, :cancelled]

    enum :status, STATUSES.to_h { |status| [status, status.to_s] }

    after_save :instrument_status_change

    validate :task_name_belongs_to_a_valid_task, on: :create
    validate :csv_attachment_presence, on: :create
    validate :csv_content_type, on: :create
    validate :validate_task_arguments, on: :create

    attr_readonly :task_name

    if Rails.gem_version >= Gem::Version.new("7.1.alpha")
      serialize :backtrace, coder: YAML
      serialize :arguments, coder: JSON
      serialize :metadata, coder: JSON
    else
      serialize :backtrace
      serialize :arguments, JSON
      serialize :metadata, JSON
    end

    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :completed, -> { where(status: COMPLETED_STATUSES) }

    # Ensure ActiveStorage is in use before preloading the attachments
    scope :with_attached_csv, -> do
      return unless defined?(ActiveStorage)

      with_attached_csv_file if ActiveStorage::Attachment.table_exists?
    end

    validates_with RunStatusValidator, on: :update

    if MaintenanceTasks.active_storage_service.present?
      has_one_attached :csv_file,
        service: MaintenanceTasks.active_storage_service
    elsif respond_to?(:has_one_attached)
      has_one_attached :csv_file
    end

    # Sets the run status to enqueued, making sure the transition is validated
    # in case it's already enqueued.
    #
    # Rescues and retries status transition if an ActiveRecord::StaleObjectError
    # is encountered.
    def enqueued!
      with_stale_object_retry do
        status_will_change!
        super
      end
    end

    CALLBACKS_TRANSITION = {
      cancelled: :cancel,
      interrupted: :interrupt,
      paused: :pause,
      succeeded: :complete,
    }.transform_keys(&:to_s)

    DELAYS_PER_ATTEMPT = [0.1, 0.2, 0.4, 0.8, 1.6]
    MAX_RETRIES = DELAYS_PER_ATTEMPT.size

    private_constant :CALLBACKS_TRANSITION, :DELAYS_PER_ATTEMPT, :MAX_RETRIES

    # Saves the run, persisting the transition of its status, and all other
    # changes to the object.
    def persist_transition
      retry_count = 0
      begin
        save!
      rescue ActiveRecord::StaleObjectError
        if retry_count < MAX_RETRIES
          sleep(DELAYS_PER_ATTEMPT[retry_count])
          retry_count += 1

          success = succeeded?
          reload_status
          if success
            self.status = :succeeded
          else
            job_shutdown
          end

          retry
        else
          raise
        end
      end

      callback = CALLBACKS_TRANSITION[status]
      run_task_callbacks(callback) if callback
    end

    # Increments +tick_count+ by +number_of_ticks+ and +time_running+ by
    # +duration+, both directly in the DB.
    # The attribute values are not set in the current instance, you need
    # to reload the record.
    #
    # @param number_of_ticks [Integer] number of ticks to add to tick_count.
    # @param duration [Float] the time in seconds that elapsed since the last
    #   increment of ticks.
    def persist_progress(number_of_ticks, duration)
      self.class.update_counters(
        id,
        tick_count: number_of_ticks,
        time_running: duration,
        touch: true,
      )
    end

    # Marks the run as errored and persists the error data.
    #
    # @param error [StandardError] the Error being persisted.
    def persist_error(error)
      with_stale_object_retry do
        self.started_at ||= Time.now
        update!(
          status: :errored,
          error_class: truncate(:error_class, error.class.name),
          error_message: truncate(:error_message, error.message),
          backtrace: MaintenanceTasks.backtrace_cleaner.clean(error.backtrace),
          ended_at: Time.now,
        )
      end
      run_error_callback
    end

    # Refreshes the status and lock version attributes on the Active Record
    # object, and ensures ActiveModel::Dirty doesn't mark the object as changed.
    #
    # This allows us to get the Run's most up-to-date status without needing
    # to reload the entire record.
    #
    # @return [MaintenanceTasks::Run] the Run record with its updated status.
    def reload_status
      columns_to_reload = if locking_enabled?
        [:status, self.class.locking_column]
      else
        [:status]
      end
      updated_status, updated_lock_version = self.class.uncached do
        self.class.where(id: id).pluck(*columns_to_reload).first
      end

      self.status = updated_status
      if updated_lock_version
        self[self.class.locking_column] = updated_lock_version
      end
      clear_attribute_changes(columns_to_reload)
      self
    end

    # Returns whether the Run is stopping, which is defined as having a status
    # of pausing or cancelling. The status of cancelled is also considered
    # stopping since a Run can be cancelled while its job still exists in the
    # queue, and we want to handle it the same way as a cancelling run.
    #
    # @return [Boolean] whether the Run is stopping.
    def stopping?
      STOPPING_STATUSES.include?(status.to_sym)
    end

    # Returns whether the Run is stopped, which is defined as having a status of
    # paused, succeeded, cancelled, or errored.
    #
    # @return [Boolean] whether the Run is stopped.
    def stopped?
      completed? || paused?
    end

    # Returns whether the Run has been started, which is indicated by the
    # started_at timestamp being present.
    #
    # @return [Boolean] whether the Run was started.
    def started?
      started_at.present?
    end

    # Returns whether the Run is completed, which is defined as
    # having a status of succeeded, cancelled, or errored.
    #
    # @return [Boolean] whether the Run is completed.
    def completed?
      COMPLETED_STATUSES.include?(status.to_sym)
    end

    # Returns whether the Run is active, which is defined as
    # having a status of enqueued, running, pausing, cancelling,
    # paused or interrupted.
    #
    # @return [Boolean] whether the Run is active.
    def active?
      ACTIVE_STATUSES.include?(status.to_sym)
    end

    # Returns the duration left for the Run to finish based on the number of
    # ticks left and the average time needed to process a tick. Returns nil if
    # the Run is completed, or if tick_count or tick_total is zero.
    #
    # @return [ActiveSupport::Duration] the estimated duration left for the Run
    #   to finish.
    def time_to_completion
      return if completed? || tick_count == 0 || tick_total.to_i == 0

      processed_per_second = (tick_count.to_f / time_running)
      ticks_left = (tick_total - tick_count)
      seconds_to_finished = ticks_left / processed_per_second
      seconds_to_finished.seconds
    end

    # Marks a Run as running.
    #
    # If the run is stopping already, it will not transition to running.
    # Rescues and retries status transition if an ActiveRecord::StaleObjectError
    # is encountered.
    def running
      if locking_enabled?
        with_stale_object_retry do
          running! unless stopping?
        end
      else
        # Preserve swap-and-replace solution for data races until users
        # run migration to upgrade to optimistic locking solution
        return if stopping?

        updated = self.class.where(id: id).where.not(status: STOPPING_STATUSES)
          .update_all(status: :running, updated_at: Time.now) > 0
        if updated
          self.status = :running
          clear_attribute_changes([:status])
        else
          reload_status
        end
      end
    end

    # Starts a Run, setting its started_at timestamp and tick_total.
    #
    # @param count [Integer] the total iterations to be performed, as
    #   specified by the Task.
    def start(count)
      with_stale_object_retry do
        update!(started_at: Time.now, tick_total: count)
      end

      task.run_callbacks(:start)
    end

    # Handles transitioning the status on a Run when the job shuts down.
    def job_shutdown
      if cancelling?
        self.status = :cancelled
        self.ended_at = Time.now
      elsif pausing?
        self.status = :paused
      elsif cancelled?
      else
        self.status = :interrupted
      end
    end

    # Handles the completion of a Run, setting a status of succeeded and the
    # ended_at timestamp.
    def complete
      self.status = :succeeded
      self.ended_at = Time.now
    end

    # Cancels a Run.
    #
    # If the Run is paused, it will transition directly to cancelled, since the
    # Task is not being performed. In this case, the ended_at timestamp
    # will be updated.
    #
    # If the Run is not paused, the Run will transition to cancelling.
    #
    # If the Run is already cancelling, and has last been updated more than 5
    # minutes ago, it will transition to cancelled, and the ended_at timestamp
    # will be updated.
    def cancel
      with_stale_object_retry do
        if paused? || stuck?
          self.status = :cancelled
          self.ended_at = Time.now
          persist_transition
        else
          cancelling!
        end
      end
    end

    # Marks a Run as pausing.
    #
    # If the Run has been stuck on pausing for more than 5 minutes, it forces
    # the transition to paused. The ended_at timestamp will be updated.
    #
    # Rescues and retries status transition if an ActiveRecord::StaleObjectError
    # is encountered.
    def pause
      with_stale_object_retry do
        if stuck?
          self.status = :paused
          persist_transition
        else
          pausing!
        end
      end
    end

    # Returns whether a Run is stuck, which is defined as having a status of
    # cancelling or pausing, and not having been updated in the last 5 minutes.
    #
    # @return [Boolean] whether the Run is stuck.
    def stuck?
      (cancelling? || pausing?) && updated_at <= MaintenanceTasks.stuck_task_duration.ago
    end

    # Performs validation on the task_name attribute.
    # A Run must be associated with a valid Task to be valid.
    # In order to confirm that, the Task is looked up by name.
    def task_name_belongs_to_a_valid_task
      Task.named(task_name)
    rescue Task::NotFoundError
      errors.add(:task_name, "must be the name of an existing Task.")
    end

    # Performs validation on the presence of a :csv_file attachment.
    # A Run for a Task that uses CsvCollection must have an attached :csv_file
    # to be valid. Conversely, a Run for a Task that doesn't use CsvCollection
    # should not have an attachment to be valid. The appropriate error is added
    # if the Run does not meet the above criteria.
    def csv_attachment_presence
      if Task.named(task_name).has_csv_content? && !csv_file.attached?
        errors.add(:csv_file, "must be attached to CSV Task.")
      elsif !Task.named(task_name).has_csv_content? && csv_file.present?
        errors.add(:csv_file, "should not be attached to non-CSV Task.")
      end
    rescue Task::NotFoundError
      nil
    end

    # Performs validation on the content type of the :csv_file attachment.
    # A Run for a Task that uses CsvCollection must have a present :csv_file
    # and a content type of "text/csv" to be valid. The appropriate error is
    # added if the Run does not meet the above criteria.
    def csv_content_type
      if csv_file.present? && csv_file.content_type != "text/csv"
        errors.add(:csv_file, "must be a CSV")
      end
    rescue Task::NotFoundError
      nil
    end

    # Performs validation on the arguments to use for the Task. If the Task is
    # invalid, the errors are added to the Run.
    def validate_task_arguments
      arguments_match_task_attributes if arguments.present?
      if task.invalid?
        error_messages = task.errors
          .map { |error| "#{error.attribute.inspect} #{error.message}" }
        errors.add(
          :arguments,
          "are invalid: #{error_messages.join("; ")}",
        )
      end
    rescue Task::NotFoundError
      nil
    end

    # Fetches the attached ActiveStorage CSV file for the run. Checks first
    # whether the ActiveStorage::Attachment table exists so that we are
    # compatible with apps that are not using ActiveStorage.
    #
    # @return [ActiveStorage::Attached::One] the attached CSV file
    def csv_file
      return unless defined?(ActiveStorage)
      return unless ActiveStorage::Attachment.table_exists?

      super
    end

    # Returns a Task instance for this Run. Assigns any attributes to the Task
    # based on the Run's parameters. Note that the Task instance is not supplied
    # with :csv_content yet if it's a CSV Task. This is done in the job, since
    # downloading the CSV file can take some time.
    #
    # @return [Task] a Task instance.
    def task
      @task ||= begin
        task = Task.named(task_name).new
        if task.attribute_names.any? && arguments.present?
          task.assign_attributes(arguments)
        end

        task.metadata = metadata
        task
      rescue ActiveModel::UnknownAttributeError
        task
      end
    end

    # Returns all the run arguments with sensitive information masked.
    #
    # @return [Hash] The masked arguments.
    def masked_arguments
      return unless arguments.present?

      argument_filter.filter(arguments)
    end

    private

    def instrument_status_change
      return unless status_previously_changed? || id_previously_changed?
      return if running? || pausing? || cancelling? || interrupted?

      attr = {
        run_id: id,
        job_id: job_id,
        task_name: task_name,
        arguments: arguments,
        metadata: metadata,
        time_running: time_running,
        started_at: started_at,
        ended_at: ended_at,
      }

      attr[:error] = {
        message: error_message,
        class: error_class,
        backtrace: backtrace,
      } if errored?

      ActiveSupport::Notifications.instrument("#{status}.maintenance_tasks", attr)
    end

    def run_task_callbacks(callback)
      task.run_callbacks(callback)
    rescue Task::NotFoundError
      nil
    end

    def run_error_callback
      task.run_callbacks(:error)
    rescue
      nil
    end

    def arguments_match_task_attributes
      invalid_argument_keys = arguments.keys - task.attribute_names
      if invalid_argument_keys.any?
        error_message = <<~MSG.squish
          Unknown parameters: #{invalid_argument_keys.map(&:to_sym).join(", ")}
        MSG
        errors.add(:base, error_message)
      end
    end

    def truncate(attribute_name, value)
      limit = self.class.column_for_attribute(attribute_name).limit
      return value unless limit

      value&.first(limit)
    end

    def argument_filter
      @argument_filter ||= ActiveSupport::ParameterFilter.new(
        Rails.application.config.filter_parameters + task.masked_arguments,
      )
    end

    def with_stale_object_retry(retry_count = 0)
      yield
    rescue ActiveRecord::StaleObjectError
      if retry_count < MAX_RETRIES
        sleep(stale_object_retry_delay(retry_count))
        retry_count += 1
        reload_status

        retry
      else
        raise
      end
    end

    def stale_object_retry_delay(retry_count)
      delay = DELAYS_PER_ATTEMPT[retry_count]
      # Add jitter (±25% randomization) to prevent thundering herd
      jitter = delay * 0.25
      delay + (rand * 2 - 1) * jitter
    end
  end
end
