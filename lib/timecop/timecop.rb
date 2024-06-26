require 'singleton'
require File.join(File.dirname(__FILE__), "time_stack_item")

# Timecop
# * Wrapper class for manipulating the extensions to the Time, Date, and DateTime objects
# * Allows us to "freeze" time in our Ruby applications.
# * Optionally allows time travel to simulate a running clock, such time is not technically frozen.
#
# This is very useful when your app's functionality is dependent on time (e.g.
# anything that might expire).  This will allow us to alter the return value of
# Date.today, Time.now, and DateTime.now, such that our application code _never_ has to change.
class Timecop
  include Singleton

  class << self
    private :instance

    # Allows you to run a block of code and "fake" a time throughout the execution of that block.
    # This is particularly useful for writing test methods where the passage of time is critical to the business
    # logic being tested.  For example:
    #
    #   joe = User.find(1)
    #   joe.purchase_home()
    #   assert !joe.mortgage_due?
    #   Timecop.freeze(2008, 10, 5) do
    #     assert joe.mortgage_due?
    #   end
    #
    # freeze and travel will respond to several different arguments:
    # 1. Timecop.freeze(time_inst)
    # 2. Timecop.freeze(datetime_inst)
    # 3. Timecop.freeze(date_inst)
    # 4. Timecop.freeze(offset_in_seconds)
    # 5. Timecop.freeze(year, month, day, hour=0, minute=0, second=0)
    # 6. Timecop.freeze() # Defaults to Time.now
    #
    # When a block is also passed, Time.now, DateTime.now and Date.today are all reset to their
    # previous values after the block has finished executing.  This allows us to nest multiple
    # calls to Timecop.travel and have each block maintain it's concept of "now."
    #
    # The Process.clock_gettime call mocks both CLOCK::MONOTIC and CLOCK::REALTIME
    #
    # CLOCK::MONOTONIC works slightly differently than other clocks. This clock cannot move to a
    # particular date/time. So the only option that changes this clock is #4 which will move the
    # clock the requested offset. Otherwise the clock is frozen to the current tick.
    #
    # * Note: Timecop.freeze will actually freeze time.  This can cause unanticipated problems if
    #   benchmark or other timing calls are executed, which implicitly expect Time to actually move
    #   forward.
    #
    # * Rails Users: Be especially careful when setting this in your development environment in a
    #   rails project.  Generators will load your environment, including the migration generator,
    #   which will lead to files being generated with the timestamp set by the Timecop.freeze call
    #   in your dev environment
    #
    # Returns the value of the block if one is given, or the mocked time.
    def freeze(*args, &block)
      send_travel(:freeze, *args, &block)
    end

    # Allows you to run a block of code and "fake" a time throughout the execution of that block.
    # See Timecop#freeze for a sample of how to use (same exact usage syntax)
    #
    # * Note: Timecop.travel will not freeze time (as opposed to Timecop.freeze).  This is a particularly
    #   good candidate for use in environment files in rails projects.
    #
    # Returns the value of the block if one is given, or the mocked time.
    def travel(*args, &block)
      send_travel(:travel, *args, &block)
    end

    # Allows you to run a block of code and "scale" a time throughout the execution of that block.
    # The first argument is a scaling factor, for example:
    #   Timecop.scale(2) do
    #     ... time will 'go' twice as fast here
    #   end
    # See Timecop#freeze for exact usage of the other arguments
    #
    # Returns the value of the block if one is given, or the mocked time.
    def scale(*args, &block)
      send_travel(:scale, *args, &block)
    end

    def baseline
      instance.baseline
    end

    def baseline=(baseline)
      instance.baseline = baseline
    end

    # Reverts back to system's Time.now, Date.today and DateTime.now (if it exists) permamently when
    # no block argument is given, or temporarily reverts back to the system's time temporarily for
    # the given block.
    def return(&block)
      if block_given?
        instance.return(&block)
      else
        instance.unmock!
        nil
      end
    end
    alias :unfreeze :return

    def return_to_baseline
      instance.return_to_baseline
      Time.now
    end

    def top_stack_item #:nodoc:
      instance.stack.last
    end

    def safe_mode=(safe)
      @safe_mode = safe
    end

    def safe_mode?
      @safe_mode ||= false
    end

    def thread_safe=(t)
      instance.thread_safe = t
    end

    def thread_safe
      instance.thread_safe
    end

    # Returns whether or not Timecop is currently frozen
    def frozen?
      !instance.stack.empty? && instance.stack.last.mock_type == :freeze
    end

    # Returns whether or not Timecop is currently travelled
    def travelled?
      !instance.stack.empty? && instance.stack.last.mock_type == :travel
    end

    # Returns whether or not Timecop is currently scaled
    def scaled?
      !instance.stack.empty? && instance.stack.last.mock_type == :scale
    end

    def mock_process_clock=(mock)
      @mock_process_clock = mock
    end

    def mock_process_clock?
      @mock_process_clock ||= false
    end

    private
    def send_travel(mock_type, *args, &block)
      val = instance.travel(mock_type, *args, &block)
      block_given? ? val : Time.now
    end
  end

  def baseline=(b)
    set_baseline(b)
    stack << TimeStackItem.new(:travel, b)
  end

  def baseline
    if @thread_safe
      Thread.current[:timecop_baseline]
    else
      @baseline
    end
  end

  def set_baseline(b)
    if @thread_safe
      Thread.current[:timecop_baseline] = b
    else
      @baseline = b
    end
  end

  def stack
    if @thread_safe
      Thread.current[:timecop_stack] ||= []
      Thread.current[:timecop_stack]
    else
      @stack
    end
  end

  def set_stack(s)
    if @thread_safe
      Thread.current[:timecop_stack] = s
    else
      @stack = s
    end
  end

  def initialize #:nodoc:
    @stack = []
    @safe = nil
    @thread_safe = false
  end

  def thread_safe=(t)
    initialize
    @thread_safe = t
  end

  def thread_safe
    @thread_safe
  end

  def travel(mock_type, *args, &block) #:nodoc:
    raise SafeModeException if Timecop.safe_mode? && !block_given? && !@safe

    stack_item = TimeStackItem.new(mock_type, *args)

    stack_backup = stack.dup
    stack << stack_item

    if block_given?
      safe_backup = @safe
      @safe = true
      begin
        yield stack_item.time
      ensure
        stack.replace stack_backup
        @safe = safe_backup
      end
    end
  end

  def return(&block)
    current_stack = stack
    current_baseline = baseline
    unmock!
    yield
  ensure
    set_stack current_stack
    set_baseline current_baseline
  end

  def unmock! #:nodoc:
    set_baseline nil
    set_stack []
  end

  def return_to_baseline
    if baseline
      set_stack [stack.shift]
    else
      unmock!
    end
  end

  class SafeModeException < StandardError
    def initialize
      super "Safe mode is enabled, only calls passing a block are allowed."
    end
  end
end

# This must be done after TimeCop is available
require File.join(File.dirname(__FILE__), "time_extensions")
