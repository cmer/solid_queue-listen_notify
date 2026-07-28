# frozen_string_literal: true

module SolidQueue
  module ListenNotify
    # Pure-Ruby replication of SolidQueue::QueueSelector's string matching, so that
    # routing a notification to workers costs no database queries.
    #
    # Matching is asymmetric on purpose: a false positive only causes a worker to
    # poll and find nothing, while a false negative costs latency. Where exact
    # parity would require a query, we over-match.
    module QueueMatcher
      # Everything before the first character that means something other than
      # itself once QueueSelector has turned the entry into a LIKE pattern.
      WAKE_PREFIX = /\A[^*%_\\]*/

      def self.matches?(raw_queues, queue_name)
        queues = Array(raw_queues).map { |queue| queue.to_s.strip }
        # QueueSelector uses `.presence || [ "*" ]`, so only a fully empty list
        # becomes "all queues"; a list of blank strings stays as it is.
        queues = [ "*" ] if queues.empty?
        queue_name = queue_name.to_s

        # The final `else` covers leading or interior "*" (e.g. "*foo", "a*b"),
        # which QueueSelector#eligible_queues drops silently.
        queues.any? do |queue|
          case
          when queue == "*" then true
          when !queue.include?("*") then queue == queue_name
          when queue.end_with?("*") then queue_name.start_with?(prefix_of(queue))
          else false
          end
        end
      end

      # The literal head an entry's LIKE pattern is anchored on.
      #
      # QueueSelector matches an entry ending in "*" with
      # `LIKE entry.tr("*", "%")`, so "foo*bar*" becomes `LIKE 'foo%bar%'`. In a
      # LIKE pattern "%" matches any run of characters, "_" matches exactly ONE
      # character, and "\" escapes the next one — and QueueSelector passes the
      # queue name through untouched, so a "_" or a "%" or a "\" the user typed
      # in a queue name is a metacharacter by the time Postgres sees it.
      #
      # That is why the prefix stops at the FIRST metacharacter rather than at
      # the first "*": "user_*" becomes `LIKE 'user_%'`, which Postgres happily
      # matches against "users" (the "_" eats the "s") — and a worker listening
      # on "user_*" therefore really does claim "users". Anchoring on "user_"
      # would miss it; anchoring on "user" cannot.
      #
      # The rule is safe in general: any string matching `LIKE 'lit<meta>rest'`
      # must begin with the literal head "lit", because nothing before the first
      # metacharacter can match anything but itself. Prefix-matching on the
      # literal head is therefore always at least as wide as the LIKE — it
      # over-matches, never under-matches. An entry that BEGINS with a
      # metacharacter ("_foo*", "%*") yields an empty prefix and so matches every
      # queue name, which is over-inclusive and correct.
      #
      # Entries WITHOUT a "*" are not affected: QueueSelector compares those with
      # `=`, where "_" and "%" are ordinary characters, so they stay exact.
      def self.prefix_of(queue)
        queue[WAKE_PREFIX]
      end
      private_class_method :prefix_of
    end
  end
end
