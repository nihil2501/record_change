# frozen_string_literal: true

module RecordChange
  class Window
    MIN_MIN_FINISH_AGE = 60.seconds
    MIN_FINISH_AGE = [
      ENV["RECORD_CHANGE_WINDOW_BUFFER"].to_i.seconds,
      MIN_MIN_FINISH_AGE
    ].max

    class << self
      def open(key, max_start_age)
        window = new(key, max_start_age)

        window.open
        yield(window)
        window.close
      end
    end

    attr_accessor :start, :finish

    def initialize(key, max_start_age)
      if !max_start_age.positive?
        raise \
          ArgumentError,
          "`max_start_age` must be positive"
      end

      @key = key
      @max_start_age =
        max_start_age.finite?.presence &&
        max_start_age
    end

    def open
      # We don't want a window's finish to be too recent because a record's
      # changed timestamp refers to a moment in time during which the
      # corresponding change is in general not yet visible in the database.
      now = Time.current
      self.finish = MIN_FINISH_AGE.before(now)
      self.start = [
        UTC.at(0), # beginning of Unix epoch.
        # If the tracker's persistence is lost for some reason, we'd redo work
        # up to `@max_start_age` ago. But this is unlikely.
        @max_start_age&.before(now),
        get_tracker
      ].compact.max
    end

    def close
      return if empty?

      self.start = finish
      set_tracker(start)
    end

    def empty?
      start >= finish
    end

  private
    UTC = ActiveSupport::TimeZone["UTC"]

    def get_tracker
      Sidekiq.redis do |conn|
        value = conn.get(@key).to_s
        UTC.parse(value)
      end
    end

    def set_tracker(value)
      Sidekiq.redis do |conn|
        value = value.in_time_zone(UTC).iso8601(6)
        conn.set(@key, value)
      end
    end
  end
end
