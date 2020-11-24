require 'diffy'
require 'fileutils'
require 'frankenstein'
require 'logger'
require 'rb-inotify'
require 'service_skeleton'
require 'tempfile'

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
#    (and also potentially #config_ok? and #sleep_duration).
#    See the documentation for those methods for what they need to do.
#
# 1. Setup any file watchers you want with .watch and #watch.
#
# 1. Instantiate your new class, passing in an environment hash, and then call
#    #start.  Something like this should do the trick:
#
#        class MyConfigGenerator < ConfigSkeleton
#          # Implement all the necessary methods
#        end
#
#        MyConfigGenerator.new(ENV).start if __FILE__ == $0
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
class ConfigSkeleton < ServiceSkeleton
  # All ConfigSkeleton-related errors will be subclasses of this.
  class Error < StandardError; end

  # If you get this, someone didn't read the documentation.
  class NotImplementedError < Error; end

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

  # Create a new config generator.
  #
  # @param env [Hash<String, String>] the environment in which this config
  #   generator runs.  Typically you'll just pass `ENV` in here, but you can
  #   pass in any hash you like, for testing purposes.
  #
  def initialize(env)
    super

    hook_signal(:HUP) do
      logger.info("SIGHUP") { "received SIGHUP, triggering config regeneration" }
      regenerate_config(force_reload: true)
    end

    initialize_config_skeleton_metrics
    initialize_trigger_pipe
  end

  # Expose the write pipe which can be written to to trigger a config
  # regeneration with a forced reload; a similar mechanism is used for
  # shutdown but in that case writes are managed internally.
  #
  # Usage: config.reload_trigger.write(".") . It does not matter what
  # is written, we are only detecting that something was written.
  #
  # @return [IO]
  def reload_trigger
    @trigger_regen_w
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

    watch(*self.class.watches)

    logger.debug(logloc) { "notifier fd is #{notifier.to_io.inspect}" }

    @terminate_r, @terminate_w = IO.pipe

    loop do
      if ios = IO.select(
          [notifier.to_io, @terminate_r, @trigger_regen_r],
          [], [],
          sleep_duration.tap { |d| logger.debug(logloc) { "Sleeping for #{d} seconds" } }
      )
        if ios.first.include?(notifier.to_io)
          logger.debug(logloc) { "inotify triggered" }
          notifier.process
          regenerate_config(force_reload: true)
        elsif ios.first.include?(@terminate_r)
          logger.debug(logloc) { "triggered by termination pipe" }
          break
        elsif ios.first.include?(@trigger_regen_r)
          logger.debug(logloc) { "triggered by regen pipe" }
          regenerate_config(force_reload: true)
          initialize_trigger_pipe
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
    files.each do |f|
      if File.directory?(f)
        notifier.watch(f, :recursive, :create, :modify, :delete, :move) { |ev| logger.info("#{logloc} watcher") { "detected #{ev.flags.join(", ")} on #{ev.watcher.path}/#{ev.name}; regenerating config" } }
      else
        notifier.watch(f, :close_write) { |ev| logger.info("#{logloc} watcher") { "detected #{ev.flags.join(", ")} on #{ev.watcher.path}; regenerating config" } }
      end
    end
  end

  private

  # Sets up the read/write IO pipe for the reload trigger.
  # If the pipe already exists, close it and create a new
  # one, otherwise IO.select triggers instantly after the
  # first write, which will lead to a huge amount of config
  # regens.
  #
  # @return [void]
  #
  def initialize_trigger_pipe
    if @trigger_regen_r
      @trigger_regen_r.close
    end
    if @trigger_regen_w
      @trigger_regen_w.close
    end
    @trigger_regen_r, @trigger_regen_w = IO.pipe
  end

  # Register metrics in the ServiceSkeleton metrics registry
  #
  # @return [void]
  #
  def initialize_config_skeleton_metrics
    @config_generation = Frankenstein::Request.new("#{service_name}_generation", outgoing: false, description: "config generation", registry: metrics)

    metrics.gauge(:"#{service_name}_last_generation_timestamp", "When the last config generation run was made")
    metrics.gauge(:"#{service_name}_last_change_timestamp", "When the config file was last written to")
    metrics.counter(:"#{service_name}_reload_total", "How many times we've asked the server to reload")
    metrics.counter(:"#{service_name}_signals_total", "How many signals have been received (and handled)")
    metrics.gauge(:"#{service_name}_config_ok", "Whether the last config change was accepted by the server")

    metrics.last_generation_timestamp.set({}, 0)
    metrics.last_change_timestamp.set({}, 0)
    metrics.config_ok.set({}, 0)
  end

  # Write out a config file if one doesn't exist, or do an initial regen run
  # to make sure everything's up-to-date.
  #
  # @return [void]
  #
  def write_initial_config
    if File.exists?(config_file)
      logger.info(logloc) { "Triggering a config regen on startup to ensure config is up-to-date" }
      regenerate_config
    else
      logger.info(logloc) { "No existing config file #{config_file} found; writing one" }
      File.write(config_file, instrumented_config_data)
      metrics.last_change_timestamp.set({}, Time.now.to_f)
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
      @config_generation.measure { config_data.tap { metrics.last_generation_timestamp.set({}, Time.now.to_f) } }
    rescue => ex
      log_exception(ex, logloc) { "Call to config_data raised exception" }
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

  # The instance of INotify::Notifier that is holding our file watches.
  #
  # @return [INotify::Notifier]
  #
  def notifier
    @notifier ||= INotify::Notifier.new
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
    logger.debug(logloc) { "force? #{force_reload.inspect}" }
    tmpfile = Tempfile.new(service_name, File.dirname(config_file))
    logger.debug(logloc) { "Tempfile is #{tmpfile.path}" }
    unless (new_config = instrumented_config_data).nil?
      File.write(tmpfile.path, new_config)
      tmpfile.close
      logger.debug(logloc) { require 'digest/md5'; "Existing config hash: #{Digest::MD5.hexdigest(File.read(config_file))}, new config hash: #{Digest::MD5.hexdigest(File.read(tmpfile.path))}" }

      match_perms(config_file, tmpfile.path)

      diff = Diffy::Diff.new(config_file, tmpfile.path, source: 'files', context: 3, include_diff_info: true)
      if diff.to_s != ""
        logger.info(logloc) { "Config has changed.  Diff:\n#{diff.to_s}" }
      end

      if force_reload
        logger.debug(logloc) { "Forcing config reload because force_reload == true" }
      end

      if force_reload || diff.to_s != ""
        cycle_config(tmpfile.path)
      end
    end
  ensure
    metrics.last_change_timestamp.set({}, File.stat(config_file).mtime.to_f)
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
      metrics.reload_total.increment(status: "failure")

      return
    end

    logger.debug(logloc) { "Server reloaded successfully" }

    if config_ok?
      metrics.config_ok.set({}, 1)
      logger.debug(logloc) { "Configuration successfully updated." }
      metrics.reload_total.increment(status: "success")
      metrics.last_change_timestamp.set({}, Time.now.to_f)
    else
      metrics.config_ok.set({}, 0)
      if config_was_ok
        logger.warn(logloc) { "New config file failed config_ok? test; rolling back to previous known-good config" }
        File.rename(old_copy, config_file)
        reload_server
        metrics.reload_total.increment(status: "bad-config")
      else
        logger.warn(logloc) { "New config file failed config_ok? test; leaving new config in place because old config is broken too" }
        metrics.reload_total.increment(status: "everything-is-awful")
        metrics.last_change_timestamp.set({}, Time.now.to_f)
      end
    end
  ensure
    File.unlink(old_copy) rescue nil
  end
end
