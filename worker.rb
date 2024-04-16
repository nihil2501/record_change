# frozen_string_literal: true

module RecordChange
  class Worker
    include Sidekiq::Worker

    sidekiq_options retry: false

    class Error < RuntimeError; end
    class MaxCountExceeded < Error; end

    def perform(processor, **args)
      @processor = processor.to_s.constantize
      @args = args

      open_window do |window|
        @window = window
        log(:info, 'start')

        begin
          unless records.empty?
            @processor.process(records, **@args)
          end
        rescue => ex
          log(:error, ex)
          raise ex
        end

        log(:info, "finish processed_count=#{records.size}")
      end
    end

  private
    def records
      unless defined?(@records)
        @records = []
        if @processor::EXCESSIVE_COUNT.positive? && !@window.empty?
          @records =
            @processor.fetch(
              from: @window.start,
              to: @window.finish,
              **@args
            ).to_a
        end

        if @records.size >= @processor::EXCESSIVE_COUNT
          unless @records.empty? # `EXCESSIVE_COUNT` must be `0`
            @window.finish = @processor.changed_at(@records.last)
          end

          keep =
            @records.find_index { |record|
              @processor.changed_at(record) >=
              @window.finish
            }.to_i

          if keep.zero?
            # If we got here, then more records were detected as having changed
            # in the same instant than the maximum amount of work we want to
            # perform in one pass. This situation defeats our scheduling
            # strategy because our windows can't cleanly find all records.
            raise \
              MaxCountExceeded,
              "#{tag} exceeded #{@processor::EXCESSIVE_COUNT} records"
          end

          drop = @records.size - keep
          @records.pop(drop)
        end
      end

      @records
    end

    def open_window(&block)
      key = [tag.dasherize, *@args.to_a].join('-')
      key = "#{key}-processed-up-to"

      # What follows describes two probably disjoint concepts that, for now, can
      # both be expressed in terms of one mechanism. One concept is idempotency
      # and keeping things in sync with one another, and the other concept is
      # side-effects that are too out of date to want to run anymore.
      #
      # Stale age is a way to express that some processing should not look too
      # far back for work. For example, sending SMS could be a bad idea after
      # too much time has passed.
      #
      # Some processors are oriented towards propogating the consequence of one
      # model change on another model, thereby keeping them in sync. These want
      # to account for all records. It's possible to express this in terms of a
      # stale age as well where the age is infinite.
      max_start_age = @processor::STALE_AGE

      Window.open(key, max_start_age, &block)
    end

    def log(level, message)
      metadata = {
        processor: tag,
        window_start: @window.start,
        **@args
      }

      metadata = metadata.map { |k,v| "#{k}=#{v}" }.join(' ')
      message = "record_change_worker #{metadata} #{message}"
      Rails.logger.send(level, message)
    end

    def tag
      @processor.to_s.
        remove('RecordChange::Processor::').
        underscore
    end
  end
end
