# frozen_string_literal: true

require 'diffy'
require 'fileutils'
require 'frankenstein'
require 'logger'
require 'service_skeleton'
require 'tempfile'
require 'digest/md5'

begin
  require 'rb-inotify' unless ENV["DISABLE_INOTIFY"]
rescue FFI::NotFoundError => e
  STDERR.puts "ERROR: Unable to initialize rb-inotify. To disable, set DISABLE_INOTIFY=1"
  raise
end

# Framework for creating config generation systems.
#
# There are many systems which require some sort of configuration file to
# operate, and need that configuration to by dynamic over time.  The intent
# of this class is to provide a common pattern for config generators, with
# solutions for common problems like monitoring, environment variables, and
# signal handling.
#
# To use this class for your own config generator, you need to:
#
# 1. Subclass this class.
#
# 1. Declare all the environment variables you care about, with the
#    ServiceSkeleton declaration methods `string`, `integer`, etc.
#
# 1. Implement service-specific config generation and reloading code, by
#    overriding the private methods #config_file, #config_data, and #reload_server
#    (and also potentially #config_ok?, #sleep_duration, #before_regenerate_config, and #after_regenerate_config).
#    See the documentation for those methods for what they need to do.
#
# 1. Setup any file watchers you want with .watch and #watch.
#
# 1. Use the ServiceSkeleton Runner to start the service. Something like this should do the trick:
#
#        class MyConfigGenerator < ConfigSkeleton
#          # Implement all the necessary methods
#        end
#
#        ServiceSkeleton::Runner.new(MyConfigGenerator, ENV).run if __FILE__ == $0
#
# 1. Sit back and relax.
#
#
# # Environment Variables
#
# In keeping with the principles of the [12 factor app](https://12factor.net),
# all configuration of the config generator should generally be done via the
# process environment.  To make this easier, ConfigSkeleton leverages
# [ServiceSkeleton's configuration
# system](https://github.com/discourse/service_skeleton#configuration) to allow
# you to declare environment variables of various types, provide defaults, and
# access the configuration values via the `config` method.  See the
# [ServiceSkeleton
# documentation](https://github.com/discourse/service_skeleton#configuration)
# for more details on how all this is accomplished.
#
#
# # Signal Handling
#
# Config generators automatically hook several signals when they are created:
#
# * **`SIGHUP`**: Trigger a regeneration of the config file and force a reload
#   of the associated server.
#
# * **`SIGINT`/`SIGTERM`**: Immediately terminate the process.
#
# * **`SIGUSR1`/`SIGUSR2`**: Increase (`USR1`) or decrease (`USR2`) the verbosity
#   of log messages output.
#
#
# # Exported Metrics
#
# No modern system is complete without Prometheus metrics.  These can be scraped
# by making a HTTP request to the `/metrics` path on the port specified by the
# `<SERVICEPREFIX>_METRICS_PORT` environment variable (if no port is specified,
# the metrics server is turned off, for security).  The metrics server will provide
# the config generator-specific metrics by default:
#
# * **`<prefix>_generation_requests_total: The number of times the config generator
#   has tried to generate a new config.  This includes any attempts that failed
#   due to exception.
#
# * **`<prefix>_generation_request_duration_seconds{,_sum,_count}`**: A
#   histogram of the amount of time taken for the `config_data` method to
#   generate a new config.
#
# * **`<prefix>_generation_exceptions_total`**: A set of counters which record
#   the number of times the `config_data` method raised an exception, labelled
#   with the `class` of the exception that occurred.  The backtrace and error
#   message should also be present in the logs.
#
# * ** `<prefix>_generation_in_progress_count`**: A gauge that should be either
#   `1` or `0`, depending on whether the `config_data` method is currently being
#   called.
#
# * **`<prefix>_last_generation_timestamp`**: A floating-point number of seconds
#   since the Unix epoch indicating when a config was last successfully generated.
#   This timestamp is updated every time the config generator checks to see if
#   the config has changed, whether or not a new config is written.
#
# * **`<prefix>_last_change_timestamp`**: A floating-point number of seconds since
#   the Unix epoch indicating when the config was last changed (that is, a new
#   config file written and the server reloaded).
#
# * **`<prefix>_reload_total`**: A set of counters indicating the number of
#   times the server has been asked to reload, usually as the result of a changed
#   config file, but potentially also due to receiving a SIGHUP.  The counters are
#   labelled by the `status` of the reload: `"success"` (all is well), `"failure"`
#   (the attempt to reload failed, indicating a problem in the `reload_server`
#   method), `"bad-config"` (the server reload succeeded, but the `config_ok?`
#   check subsequently failed), or `"everything-is-awful"` (the `config_ok?`
#   check failed both before *and* after the reload, indicating something is
#   *very* wrong with the underlying server).
#
# * **`<prefix>_signals_total`**: A set of counters indicating how many of each
#   signal have been received, labelled by `signal`.
#
# * **`<prefix>_config_ok`**: A gauge that should be either `1` or `0`, depending on
#   whether the last generated config was loaded successfully by the server.
#   If the #config_ok? method has not been overridden, this will always be `1`.
#
# Note that all of the above metrics have a `<prefix>` at the beginning; the
# value of this is derived from the class name, by snake-casing.
#
#
# # Watching files
#
# Sometimes your config, or the server, relies on other files on the filesystem
# managed by other systems (typically a configuration management system), and
# when those change, the config needs to change, or the server needs to be
# reloaded.  To accommodate this requirement, you can declare a "file watch"
# in your config generator, and any time the file or directory being watched
# changes, a config regeneration and server reload will be forced.
#
# To declare a file watch, just call the .watch class method, or #watch instance
# method, passing one or more strings containing the full path to files or
# directories to watch.
#
class ConfigSkeleton
  include ServiceSkeleton

  # All ConfigSkeleton-related errors will be subclasses of this.
  class Error < StandardError; end

  # If you get this, someone didn't read the documentation.
  class NotImplementedError < Error; end

  # It is useful for consumers to manually request a config regen. An instance
  # of this class is made via the regen_notifier method.
  class ConfigRegenNotifier
    def initialize(io_write)
      @io_write = io_write
    end

    def trigger_regen
      @io_write << "."
    end
  end

  def self.inherited(klass)
    klass.boolean "#{klass.service_name.upcase}_CONFIG_ONESHOT".to_sym, default: false

    klass.gauge :"#{klass.service_name}_config_ok", docstring: "Whether the last config change was accepted by the server"
    klass.gauge :"#{klass.service_name}_generation_ok", docstring: "Whether the last config generation completed without error"
    klass.gauge :"#{klass.service_name}_last_generation_timestamp", docstring: "When the last config generation run was made"
    klass.gauge :"#{klass.service_name}_last_change_timestamp", docstring: "When the config file was last written to"
    klass.counter :"#{klass.service_name}_reload_total", docstring: "How many times we've asked the server to reload", labels: [:status]
    klass.counter :"#{klass.service_name}_signals_total", docstring: "How many signals have been received (and handled)"

    klass.hook_signal("HUP") do
      logger.info("SIGHUP") { "received SIGHUP, triggering config regeneration" }
      @trigger_regen_w << "."
    end
  end

  # Declare a file watch on all instances of the config generator.
  #
  # When you're looking to watch a file whose path is well-known and never-changing, you
  # can declare the watch in the class.
  #
  # @param f [String] one or more file paths to watch.
  #
  # @return [void]
  #
  # @example reload every time a logfile is written to
  #    class MyConfig
  #      watch "/var/log/syslog"
  #    end
  #
  # @see #watch for more details on how file and directory watches work.
  #
  def self.watch(*f)
    @watches ||= []
    @watches += f
  end

  # Retrieve the list of class-level file watches.
  #
  # Not interesting for most users.
  #
  # @return [Array<String>]
  #
  def self.watches
    @watches || []
  end

  def initialize(*_, metrics:, config:)
    super
    initialize_config_skeleton_metrics
    @trigger_regen_r, @trigger_regen_w = IO.pipe
    @terminate_r, @terminate_w = IO.pipe

    raise "cooldown_duration invalid" if cooldown_duration < 0
    raise "sleep_duration invalid" if sleep_duration < 0
    raise "sleep_duration must not be less than cooldown_duration" if sleep_duration < cooldown_duration
  end

  # Expose the write pipe which can be written to to trigger a config
  # regeneration with a forced reload; a similar mechanism is used for
  # shutdown but in that case writes are managed internally.
  #
  # Usage: config.regen_notifier.trigger_regen
  #
  # @return [ConfigRegenNotifier]
  def regen_notifier
    @regen_notifier ||= ConfigRegenNotifier.new(@trigger_regen_w)
  end

  # Set the config generator running.
  #
  # Does the needful to generate configs and reload the server.  Typically
  # never returns, unless you send the process a `SIGTERM`/`SIGINT`.
  #
  # @return [void]
  #
  def run
    logger.info(logloc) { "Commencing config management" }

    write_initial_config

    if config.config_oneshot
      logger.info(logloc) { "Oneshot run specified - exiting" }
      Process.kill("TERM", $PID)
    end

    watch(*self.class.watches)

    logger.debug(logloc) { "notifier fd is #{notifier.to_io.inspect}" }

    loop do
      if cooldown_duration > 0
        logger.debug(logloc) { "Sleeping for #{cooldown_duration} seconds (cooldown)" }
        IO.select([@terminate_r], [], [], cooldown_duration)
      end

      timeout = sleep_duration - cooldown_duration
      logger.debug(logloc) { "Sleeping for #{timeout} seconds unless interrupted" }
      ios = IO.select([notifier.to_io, @terminate_r, @trigger_regen_r], [], [], timeout)

      if ios
        if ios.first.include?(notifier.to_io)
          logger.debug(logloc) { "inotify triggered" }
          notifier.process
          regenerate_config(force_reload: true)
        elsif ios.first.include?(@terminate_r)
          logger.debug(logloc) { "triggered by termination pipe" }
          break
        elsif ios.first.include?(@trigger_regen_r)
          # we want to wait until everything in the backlog is read
          # before proceeding so we don't run out of buffer memory
          # for the pipe
          while @trigger_regen_r.read_nonblock(20, nil, exception: false) != :wait_readable; end

          logger.debug(logloc) { "triggered by regen pipe" }
          regenerate_config(force_reload: true)
        else
          logger.error(logloc) { "Mysterious return from select: #{ios.inspect}" }
        end
      else
        logger.debug(logloc) { "triggered by timeout" }
        regenerate_config
      end
    end
  end

  # Trigger the run loop to stop running.
  #
  def shutdown
    @terminate_w.write(".")
  end

  # Setup a file watch.
  #
  # If the files you want to watch could be in different places on different
  # systems (for instance, if your config generator's working directory can be
  # configured via environment), then you'll need to call this in your
  # class' initialize method to setup the watch.
  #
  # Watching a file, for our purposes, simply means that whenever it is modified,
  # the config is regenerated and the server process reloaded.
  #
  # Watches come in two flavours: *file* watches, and *directory* watches.
  # A file watch is straightforward: if the contents of the file are
  # modified, off we go.  For a directory, if a file is created in the
  # directory, or deleted from the directory, or *if any file in the
  # directory is modified*, the regen/reload process is triggered.  Note
  # that directory watches are recursive; all files and subdirectories under
  # the directory specified will be watched.
  #
  # @param files [Array<String>] the paths to watch for changes.
  #
  # @return [void]
  #
  # @see .watch for watching files and directories whose path never changes.
  #
  def watch(*files)
    return if ENV["DISABLE_INOTIFY"]
    files.each do |f|
      if File.directory?(f)
        notifier.watch(f, :recursive, :create, :modify, :delete, :move) { |ev| logger.info("#{logloc} watcher") { "detected #{ev.flags.join(", ")} on #{ev.watcher.path}/#{ev.name}; regenerating config" } }
      else
        notifier.watch(f, :close_write) { |ev| logger.info("#{logloc} watcher") { "detected #{ev.flags.join(", ")} on #{ev.watcher.path}; regenerating config" } }
      end
    end
  end

  private

  def initialize_config_skeleton_metrics
    @config_generation = Frankenstein::Request.new("#{self.class.service_name}_generation", outgoing: false, description: "config generation", registry: metrics)
    metrics.last_generation_timestamp.set(0)
    metrics.last_change_timestamp.set(0)
    metrics.config_ok.set(0)
    metrics.generation_ok.set(0)
  end

  # Write out a config file if one doesn't exist, or do an initial regen run
  # to make sure everything's up-to-date.
  #
  # @return [void]
  #
  def write_initial_config
    if File.exist?(config_file)
      logger.info(logloc) { "Triggering a config regen on startup to ensure config is up-to-date" }
      regenerate_config
    else
      logger.info(logloc) { "No existing config file #{config_file} found; writing one" }
      File.write(config_file, instrumented_config_data)
      metrics.last_change_timestamp.set(Time.now.to_f)
    end
  end

  # The file in which the config should be written.
  #
  # @note this *must* be implemented by subclasses.
  #
  # @return [String] the absolute path to the config file to write.
  #
  def config_file
    raise NotImplementedError, "config_file must be implemented in subclass."
  end

  # Generate a configuration data string.
  #
  # @note this *must* be implemented by subclasses.
  #
  # This should return the desired contents of the configuration file as at
  # the moment it is called.  It will be compared against the current contents
  # of the config file to determine whether the server needs to be reloaded.
  #
  # @return [String] the desired contents of the configuration file.
  #
  def config_data
    raise NotImplementedError, "config_data must be implemented in subclass."
  end

  # Run code before the config is regenerated and the config_file
  # is written.
  #
  # @param force_reload [Boolean] Whether the regenerate_config was called with force_reload
  # @param existing_config_hash [String] MD5 hash of the config file before regeneration.
  #
  # @note this can optionally be implemented by subclasses.
  #
  def before_regenerate_config(force_reload:, existing_config_hash:, existing_config_data:); end

  # Run code after the config is regenerated and potentially a new file is written.
  #
  # @param force_reload [Boolean] Whether the regenerate_config was called with force_reload
  # @param config_was_different [Boolean] Whether the diff of the old and new config was different.
  # @param config_was_cycled [Boolean] Whether a new config file was cycled in.
  # @param new_config_hash [String] MD5 hash of the new config file after write.
  #
  # @note this can optionally be implemented by subclasses.
  #
  def after_regenerate_config(force_reload:, config_was_different:, config_was_cycled:, new_config_hash:); end

  # Verify that the currently running config is acceptable.
  #
  # In the event that a generated config is "bad", it may be possible to detect
  # that the server hasn't accepted the new config, and if so, the config can
  # be rolled back to a known-good state and the `<prefix>_config_ok` metric
  # set to `0` to indicate a problem.  Not all servers are able to be
  # interrogated for correctness, so by default the config_ok? check is a no-op,
  # but where possible it should be used, as it is a useful safety net and
  # monitoring point.
  #
  def config_ok?
    true
  end

  # Perform a reload of the server that consumes this config.
  #
  # The vast majority of services out there require an explicit "kick" to
  # read a new configuration, whether that's being sent a SIGHUP, or a request
  # to a special URL, or even a hard restart.  That's what this method needs
  # to do.
  #
  # If possible, this method should not return until the reload is complete,
  # because the next steps after reloading the server assume that the server
  # is available and the new config has been loaded.
  #
  # @raise [StandardError] this method can raise any exception, and it will
  #   be caught and logged by the caller, and the reload considered "failed".
  #
  def reload_server
    raise NotImplementedError, "reload_server must be implemented in subclass."
  end

  # Internal method for calling the subclass' #config_data method, with exception
  # handling and stats capture.
  #
  # @return [String]
  #
  def instrumented_config_data
    begin
      @config_generation.measure do
        config_data.tap do
          metrics.last_generation_timestamp.set(Time.now.to_f)
          metrics.generation_ok.set(1)
        end
      end
    rescue => ex
      log_exception(ex, logloc) { "Call to config_data raised exception" }
      metrics.generation_ok.set(0)
      nil
    end
  end

  # Determine how long to sleep between attempts to proactively regenerate the config.
  #
  # Whilst signals and file watching are great for deciding when the config
  # needs to be rewritten, by far the most common reason for checking whether
  # things are changed is "because it's time to".  Thus, this method exists to
  # allow subclasses to define when that is.  The default, a hard-coded `60`,
  # just means "wake up every minute".  Some systems can get away with a much
  # longer interval, others need a shorter one, and if you're really lucky,
  # you can calculate how long to sleep based on a cache TTL or similar.
  #
  # @return [Integer] the number of seconds to sleep for.  This *must not* be
  #   negative, lest you create a tear in the space-time continuum.
  #
  def sleep_duration
    60
  end

  # How long to ignore signals/notifications after a config regeneration
  #
  # Hammering a downstream service with reload requests is often a bad idea.
  # This method exists to allow subclasses to define a 'cooldown' duration.
  # After each config regeneration, the config generator will sleep for this
  # duration, regardless of any CONT signals or inotify events. Those events
  # will be queued up, and processed at the end of the cooldown.
  #
  # The cooldown_duration is counted as part of the sleep_duration. So for
  # the default values of 60 and 5, the service will cooldown for 5s, then wait
  # for 55s.
  #
  # @return [Integer] the number of seconds to 'cooldown' for.  This *must* be
  #   greater than zero, and less than sleep_duration
  #
  def cooldown_duration
    5
  end

  # The instance of INotify::Notifier that is holding our file watches.
  #
  # @return [INotify::Notifier]
  #
  def notifier
    @notifier ||= INotify::Notifier.new
  rescue NameError
    raise if !ENV["DISABLE_INOTIFY"]
    @notifier ||= Struct.new(:to_io).new(IO.pipe[1]) # Stub for macOS development
  end

  # Do the hard yards of actually regenerating the config and performing the reload.
  #
  # @param force_reload [Boolean] normally, whether or not to tell the server
  # to reload is conditional on the new config file being different from the
  # old one.  If you want to make it happen anyway (as occurs if a `SIGHUP` is
  # received, for instance), set `force_reload: true` and we'll be really insistent.
  #
  # @return [void]
  #
  def regenerate_config(force_reload: false)
    data = File.read(config_file)
    existing_config_hash = Digest::MD5.hexdigest(data)
    before_regenerate_config(
      force_reload: force_reload,
      existing_config_hash: existing_config_hash,
      existing_config_data: data
    )

    logger.debug(logloc) { "force? #{force_reload.inspect}" }
    tmpfile = Tempfile.new(self.class.service_name, File.dirname(config_file))
    logger.debug(logloc) { "Tempfile is #{tmpfile.path}" }
    unless (new_config = instrumented_config_data).nil?
      File.write(tmpfile.path, new_config)
      tmpfile.close

      new_config_hash = Digest::MD5.hexdigest(File.read(tmpfile.path))
      logger.debug(logloc) do
        "Existing config hash: #{existing_config_hash}, new config hash: #{new_config_hash}"
      end

      match_perms(config_file, tmpfile.path)

      diff = Diffy::Diff.new(config_file, tmpfile.path, source: 'files', context: 3, include_diff_info: true).to_s
      config_was_different = diff != ""

      if config_was_different
        logger.info(logloc) { "Config has changed.  Diff:\n#{diff}" }
      end

      if force_reload
        logger.debug(logloc) { "Forcing config reload because force_reload == true" }
      end

      config_was_cycled = false
      if force_reload || config_was_different
        cycle_config(tmpfile.path)
        config_was_cycled = true
      end
    end

    after_regenerate_config(
      force_reload: force_reload,
      config_was_different: config_was_different,
      config_was_cycled: config_was_cycled,
      new_config_hash: new_config_hash
    )
  ensure
    metrics.last_change_timestamp.set(File.stat(config_file).mtime.to_f)
    tmpfile.close rescue nil
    tmpfile.unlink rescue nil
  end

  # Ensure the target file's ownership and permission bits match that of the source
  #
  # When writing a new config file, you typically want to ensure that it has the same
  # permissions as the existing one.  It's just simple politeness.  In the absence
  # of an easy-to-find method in FileUtils to do this straightforward task, we have
  # this one, instead.
  #
  # @param source [String] the path to the file whose permissions we wish to duplicate.
  # @param target [String] the path to the file whose permissions we want to change.
  # @return [void]
  #
  def match_perms(source, target)
    stat = File.stat(source)

    File.chmod(stat.mode, target)
    File.chown(stat.uid, stat.gid, target)
  end

  # Shuffle files around and reload the server
  #
  # @return [void]
  #
  def cycle_config(new_config_file)
    logger.debug(logloc) { "Cycling #{new_config_file} into operation" }

    # If the daemon isn't currently working correctly, there's no downside to
    # leaving a new, also-broken configuration in place, and it can help during
    # bootstrapping (where the daemon can't be reloaded because it isn't
    # *actually* running yet).  So, let's remember if it was working before we
    # started fiddling, and only rollback if we broke it.
    config_was_ok = config_ok?
    logger.debug(logloc) { config_was_ok ? "Current config is OK" : "Current config is a dumpster fire" }

    old_copy = "#{new_config_file}.old"
    FileUtils.copy(config_file, old_copy)
    File.rename(new_config_file, config_file)
    begin
      logger.debug(logloc) { "Reloading the server..." }
      reload_server
    rescue => ex
      log_exception(ex, logloc) { "Server reload failed" }
      if config_was_ok
        logger.debug(logloc) { "Restored previous config file" }
        File.rename(old_copy, config_file)
      end
      metrics.reload_total.increment(labels: { status: "failure" })

      return
    end

    logger.debug(logloc) { "Server reloaded successfully" }

    if config_ok?
      metrics.config_ok.set(1)
      logger.debug(logloc) { "Configuration successfully updated." }
      metrics.reload_total.increment(labels: { status: "success" })
      metrics.last_change_timestamp.set(Time.now.to_f)
    else
      metrics.config_ok.set(0)
      if config_was_ok
        logger.warn(logloc) { "New config file failed config_ok? test; rolling back to previous known-good config" }
        File.rename(old_copy, config_file)
        reload_server
        metrics.reload_total.increment(labels: { status: "bad-config" })
      else
        logger.warn(logloc) { "New config file failed config_ok? test; leaving new config in place because old config is broken too" }
        metrics.reload_total.increment(labels: { status: "everything-is-awful" })
        metrics.last_change_timestamp.set(Time.now.to_f)
      end
    end
  ensure
    File.unlink(old_copy) rescue nil
  end
end
