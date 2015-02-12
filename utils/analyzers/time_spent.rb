require 'business_time'

module Util
  module Analyzers
    class TimeSpent
      attr_reader :card_id, :times

      def initialize(card_id, actions)
        @actions = actions.sort_by(&:date)
        @card_id = card_id
        @times = {}

        @actions.reduce(nil) do |last_date, action|
          span_for(action.before_id).add last_date, action.date if last_date
          action.date
        end

        last = @actions.last
        span_for(last.after_id).add last.date, Date.today
      end

      def in(list)
        @times[list]
      end

      def as_json(opts={})
        {
          card_id: card_id,
          times: times
        }
      end

      def self.by_card(actions)
        actions.group_by(&:card_id).map {|id, card_actions| TimeSpent.new id, card_actions}
      end

      private
      def span_for(action)
        @times[action] ||= Span.new
      end

      class Span
        attr_reader :total_days, :business_days

        def initialize
          @total_days, @business_days = [0, 0]
        end

        def add(start_time, end_time)
          start_day = start_time.to_date
          end_day = end_time.to_date

          @total_days += (end_day - start_day).numerator
          @business_days += start_day.business_days_until end_day
        end

        def as_json(options={})
          {
            total_days: total_days,
            business_days: business_days
          }
        end
      end
    end
  end
end
