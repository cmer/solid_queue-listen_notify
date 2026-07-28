# frozen_string_literal: true

require "test_helper"

class QueueMatcherTest < Minitest::Test
  MATCHER = SolidQueue::ListenNotify::QueueMatcher

  # [ raw_queues, queue_name, expected, description ]
  CASES = [
    [ [ "*" ], "anything", true, "star matches any queue" ],
    [ [ "*" ], "", true, "star matches the empty queue name" ],
    [ [], "anything", true, "empty list is treated as [ \"*\" ]" ],
    [ nil, "anything", true, "nil is treated as [ \"*\" ]" ],
    [ "*", "anything", true, "a bare string is wrapped in an array" ],

    [ [ "background" ], "background", true, "exact match hits" ],
    [ [ "background" ], "backgrounds", false, "exact match doesn't hit on a prefix" ],
    [ [ "background" ], "mailers", false, "exact match misses" ],
    [ "background", "background", true, "a bare string matches exactly" ],

    [ [ "foo*" ], "foo_bar", true, "trailing star matches by prefix" ],
    [ [ "foo*" ], "foo", true, "trailing star matches the prefix itself" ],
    [ [ "foo*" ], "barfoo", false, "trailing star doesn't match a suffix" ],
    [ [ "foo*" ], "fo", false, "trailing star doesn't match a shorter name" ],

    [ [ "*foo" ], "xfoo", false, "leading star is dropped" ],
    [ [ "*foo" ], "foo", false, "leading star doesn't fall back to exact matching" ],
    [ [ "a*b" ], "ab", false, "interior star is dropped" ],
    [ [ "a*b" ], "a_b", false, "interior star doesn't match what LIKE would" ],

    # Over-inclusive on purpose: QueueSelector would run LIKE 'foo%bar%'.
    [ [ "foo*bar*" ], "foothing", true, "multiple stars match on the first prefix" ],
    [ [ "foo*bar*" ], "thingbar", false, "multiple stars still anchor on the prefix" ],
    [ [ "**" ], "anything", true, "double star matches everything" ],

    [ [ "exact", "pre*" ], "exact", true, "mixed list matches the exact entry" ],
    [ [ "exact", "pre*" ], "prefixed", true, "mixed list matches the prefixed entry" ],
    [ [ "exact", "pre*" ], "other", false, "mixed list misses everything else" ],

    [ [ :background, " mailers " ], "background", true, "symbols are stringified" ],
    [ [ :background, " mailers " ], "mailers", true, "entries are stripped" ],
    [ [ " foo* " ], "foo_bar", true, "stripping exposes a trailing star" ],

    [ [ "" ], "", true, "an empty entry matches the empty queue name" ],
    [ [ "" ], "background", false, "an empty entry matches nothing else" ],
    [ [ "", "background" ], "background", true, "empty entries don't swallow the list" ],

    [ [ "Background" ], "background", false, "exact matching is case-sensitive" ],
    [ [ "Foo*" ], "foo_bar", false, "prefix matching is case-sensitive" ],

    # LIKE metacharacters in a wildcard entry. QueueSelector runs
    # `LIKE 'user_%'` for "user_*", where the "_" matches ANY single character,
    # so the worker really does claim "users" and "userX" — the wake prefix has
    # to stop at the "_" for those to be woken at all.
    [ [ "user_*" ], "users", true, "an underscore in a wildcard entry matches any character" ],
    [ [ "user_*" ], "userX", true, "an underscore claims a name with any character in its place" ],
    [ [ "user_*" ], "user_a", true, "an underscore still claims the literal underscore" ],
    [ [ "user_*" ], "usersomething", true, "an underscore claims a longer name too" ],
    [ [ "user_*" ], "user", true, "the literal head alone is an allowed over-match" ],
    [ [ "user_*" ], "use", false, "the literal head still has to be there" ],
    [ [ "user_*" ], "other", false, "an underscore does not make the entry match everything" ],

    [ [ "real_time*" ], "realtime", true, "the prefix truncates at the underscore (over-match)" ],
    [ [ "real_time*" ], "real_time_x", true, "the literal spelling matches as well" ],
    [ [ "real_time*" ], "realXtime_x", true, "an underscore matches any single character" ],

    [ [ "50%*" ], "50off", true, "a percent in a wildcard entry matches any run of characters" ],
    [ [ "50%*" ], "50%off", true, "a percent still claims the literal percent" ],
    [ [ "a%b*" ], "aXXXb1", true, "an interior percent is a metacharacter" ],

    [ [ "_*" ], "anything", true, "an entry starting with a metacharacter matches everything" ],
    [ [ "%*" ], "anything", true, "a leading percent matches everything" ],
    [ [ "x\\y*" ], "xy1", true, "a backslash escapes the next character in the LIKE pattern" ],

    # Exact entries go through `=`, where "_" and "%" mean themselves.
    [ [ "user_high" ], "userXhigh", false, "an exact entry treats an underscore literally" ],
    [ [ "user_high" ], "user_high", true, "an exact entry matches its literal spelling" ],
    [ [ "50%off" ], "50Xoff", false, "an exact entry treats a percent literally" ]
  ].freeze

  CASES.each_with_index do |(raw_queues, queue_name, expected, description), index|
    define_method(:"test_#{index}_#{description.tr(' ', '_').gsub(/\W/, '')}") do
      assert_equal expected, MATCHER.matches?(raw_queues, queue_name),
        "expected #{raw_queues.inspect} vs #{queue_name.inspect} to be #{expected}: #{description}"
    end
  end

  def test_queue_name_is_stringified
    assert MATCHER.matches?([ "background" ], :background)
    refute MATCHER.matches?([ "background" ], nil)
    assert MATCHER.matches?([ "*" ], nil)
  end

  # Differential test against an oracle ----------------------------------------
  #
  # The matcher's whole contract is "never miss a queue SolidQueue::QueueSelector
  # would claim". The only way to check that honestly is to reimplement the
  # selector's claiming semantics independently and compare verdicts over a
  # corpus built out of every metacharacter that can appear in a queue name.
  #
  # The oracle evaluates SQL LIKE in Ruby rather than in Postgres, so this stays
  # in the unit tier. Its equivalence with a real server's LIKE is checked
  # separately by the differential probe in the development scratchpad.

  # Queue-list entries an application could plausibly (or implausibly) configure.
  ENTRIES = [
    "*", "", " ", "  ", nil, :default, "default", "DEFAULT", "Default",
    "foo", "foo*", "foo_bar", "foo_bar*", "foo%*", "foo%bar", "a%b*", "a_b*",
    "*foo", "a*b", "foo**", "f*o*", "_*", "%*", "un_icode_é*", "émail*", "émail",
    "queue.name*", "queue-name*", "with space*", "with space", "tab\there*",
    "[abc]*", "(x)*", "x\\y*", "x\\*", "50%*", "user_*", "mailers*", "real_time*"
  ].freeze

  # Payloads the trigger could send, i.e. real queue names.
  NAMES = [
    "", " ", "default", "DEFAULT", "Default", "foo", "foobar", "foo_bar", "foo_barbaz",
    "fooXbar", "fooXbarbaz", "foo%", "foo%zz", "fooQ", "aXb", "a%b", "a_b", "aQbZZ",
    "*", "*foo", "a*b", "f_o_", "fzozz", "_", "%", "x", "xy", "un_icode_é1", "unXicodeXé1",
    "émail_high", "éMAIL", "émail", "queue.name1", "queueXname1", "queue-name-x",
    "with space1", "tab\there1", "[abc]1", "(x)1", "x\\y1", "xy1", "xQy1", "x1", "50%off", "50Xoff",
    "user_high", "userXhigh", "mailers", "mailers_low", "real_time_x", "realQtimeQx"
  ].freeze

  LISTS = (ENTRIES.map { |entry| [ entry ] } + [
    [ "*", "specific" ], [ "specific", "*" ], [ "" ], [ "  " ], [ nil ], [ :a, :b ],
    [ "foo_bar*", "other" ], [ "a", "b*", "c_d*" ], [], nil, [ "", "x*" ],
    [ "foo*", "foo" ], [ "%*" ], [ "_*" ]
  ]).freeze

  def test_the_matcher_never_misses_a_queue_the_selector_would_claim
    missed = []
    checked = 0

    LISTS.each do |list|
      NAMES.each do |name|
        checked += 1
        next unless selector_claims?(list, name)

        missed << [ list, name ] unless MATCHER.matches?(list, name)
      end
    end

    assert_operator checked, :>, 2_000, "the corpus should be a few thousand pairs"
    assert_empty missed.map { |list, name| "queues=#{list.inspect} queue_name=#{name.inspect}" },
      "these queue names would be claimed by QueueSelector but never woken — a missed job is the " \
      "one failure this matcher must not have"
  end

  # The over-match direction is allowed, but it should stay a rounding error
  # rather than "wake everybody for everything".
  def test_over_matching_is_bounded
    over = 0
    total = 0

    LISTS.each do |list|
      NAMES.each do |name|
        total += 1
        over += 1 if MATCHER.matches?(list, name) && !selector_claims?(list, name)
      end
    end

    assert_operator over.to_f / total, :<, 0.15,
      "the matcher woke workers for #{over} of #{total} pairs the selector would not claim"
  end

  private
    # SolidQueue::QueueSelector, reimplemented from its published semantics:
    # blank list means "*", "*" anywhere means every queue, entries without a "*"
    # are compared with `=`, and entries ending in "*" become
    # `LIKE entry.tr("*", "%")`.
    def selector_claims?(raw_queues, queue_name)
      queues = Array(raw_queues).map { |queue| queue.to_s.strip }
      queues = [ "*" ] if queues.empty?
      queue_name = queue_name.to_s

      return true if queues.include?("*")
      return true if queues.reject { |queue| queue.include?("*") }.include?(queue_name)

      queues.select { |queue| queue.end_with?("*") }
            .any? { |queue| sql_like?(queue_name, queue.tr("*", "%")) }
    end

    # SQL LIKE, evaluated in Ruby: "%" is any run, "_" is exactly one character,
    # "\" escapes the next character, everything else is literal, and the whole
    # string has to match.
    def sql_like?(value, pattern)
      Regexp.new("\\A#{like_pattern_source(pattern)}\\z", Regexp::MULTILINE).match?(value)
    end

    def like_pattern_source(pattern)
      source = +""
      characters = pattern.each_char.to_a
      index = 0

      while index < characters.length
        case (character = characters[index])
        when "\\"
          index += 1
          source << Regexp.escape(characters[index].to_s)
        when "%" then source << ".*"
        when "_" then source << "."
        else source << Regexp.escape(character)
        end

        index += 1
      end

      source
    end
end
