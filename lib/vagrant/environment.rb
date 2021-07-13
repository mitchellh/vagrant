require 'fileutils'
require 'json'
require 'pathname'
require 'set'
require 'thread'

require 'log4r'

require 'vagrant/util/file_mode'
require 'vagrant/util/platform'
require 'vagrant/util/hash_with_indifferent_access'
require "vagrant/util/silence_warnings"
require "vagrant/vagrantfile"
require "vagrant/version"

module Vagrant
  # A "Vagrant environment" represents a configuration of how Vagrant
  # should behave: data directories, working directory, UI output,
  # etc. In day-to-day usage, every `vagrant` invocation typically
  # leads to a single Vagrant environment.
  class Environment
    # This is the current version that this version of Vagrant is
    # compatible with in the home directory.
    #
    # @return [String]
    CURRENT_SETUP_VERSION = "1.5"

    DEFAULT_LOCAL_DATA = ".vagrant"

    # The `cwd` that this environment represents
    attr_reader :cwd

    # The persistent data directory where global data can be stored. It
    # is up to the creator of the data in this directory to properly
    # remove it when it is no longer needed.
    #
    # @return [Pathname]
    attr_reader :data_dir

    # The valid name for a Vagrantfile for this environment.
    attr_reader :vagrantfile_name

    # The {UI} object to communicate with the outside world.
    attr_reader :ui

    # This is the UI class to use when creating new UIs.
    attr_reader :ui_class

    # The directory to the "home" folder that Vagrant will use to store
    # global state.
    attr_reader :home_path

    # The directory to the directory where local, environment-specific
    # data is stored.
    attr_reader :local_data_path

    # The directory where temporary files for Vagrant go.
    attr_reader :tmp_path

    # File where command line aliases go.
    attr_reader :aliases_path

    # The directory where boxes are stored.
    attr_reader :boxes_path

    # The path where the plugins are stored (gems)
    attr_reader :gems_path

    # The path to the default private key
    attr_reader :default_private_key_path

    # Initializes a new environment with the given options. The options
    # is a hash where the main available key is `cwd`, which defines where
    # the environment represents. There are other options available but
    # they shouldn't be used in general. If `cwd` is nil, then it defaults
    # to the `Dir.pwd` (which is the cwd of the executing process).
    def initialize(opts=nil)
      opts = {
        cwd:              nil,
        home_path:        nil,
        local_data_path:  nil,
        ui_class:         nil,
        vagrantfile_name: nil,
      }.merge(opts || {})

      # Set the default working directory to look for the vagrantfile
      opts[:cwd] ||= ENV["VAGRANT_CWD"] if ENV.key?("VAGRANT_CWD")
      opts[:cwd] ||= Dir.pwd
      opts[:cwd] = Pathname.new(opts[:cwd])
      if !opts[:cwd].directory?
        raise Errors::EnvironmentNonExistentCWD, cwd: opts[:cwd].to_s
      end
      opts[:cwd] = opts[:cwd].expand_path

      # Set the default ui class
      opts[:ui_class] ||= UI::Silent

      # Set the Vagrantfile name up. We append "Vagrantfile" and "vagrantfile" so that
      # those continue to work as well, but anything custom will take precedence.
      opts[:vagrantfile_name] ||= ENV["VAGRANT_VAGRANTFILE"] if \
        ENV.key?("VAGRANT_VAGRANTFILE")
      opts[:vagrantfile_name] = [opts[:vagrantfile_name]] if \
        opts[:vagrantfile_name] && !opts[:vagrantfile_name].is_a?(Array)

      # Set instance variables for all the configuration parameters.
      @cwd              = opts[:cwd]
      @home_path        = opts[:home_path]
      @vagrantfile_name = opts[:vagrantfile_name]
      @ui               = opts[:ui_class].new
      @ui_class         = opts[:ui_class]

      # This is the batch lock, that enforces that only one {BatchAction}
      # runs at a time from {#batch}.
      @batch_lock = Mutex.new

      @locks = {}

      @logger = Log4r::Logger.new("vagrant::environment")
      @logger.info("Environment initialized (#{self})")
      @logger.info("  - cwd: #{cwd}")

      # Setup the home directory
      @home_path  ||= Vagrant.user_data_path
      @home_path  = Util::Platform.fs_real_path(@home_path)
      @boxes_path = @home_path.join("boxes")
      @data_dir   = @home_path.join("data")
      @gems_path  = Vagrant::Bundler.instance.plugin_gem_path
      @tmp_path   = @home_path.join("tmp")
      @machine_index_dir = @data_dir.join("machine-index")

      @aliases_path = Pathname.new(ENV["VAGRANT_ALIAS_FILE"]).expand_path if ENV.key?("VAGRANT_ALIAS_FILE")
      @aliases_path ||= @home_path.join("aliases")

      # Prepare the directories
      setup_home_path

      # Setup the local data directory. If a configuration path is given,
      # it is expanded relative to the root path. Otherwise, we use the
      # default (which is also expanded relative to the root path).
      if !root_path.nil?
        if !ENV["VAGRANT_DOTFILE_PATH"].to_s.empty? && !opts[:child]
          opts[:local_data_path] ||= Pathname.new(File.expand_path(ENV["VAGRANT_DOTFILE_PATH"], root_path))
        else
          opts[:local_data_path] ||= root_path.join(DEFAULT_LOCAL_DATA)
        end
      end
      if opts[:local_data_path]
        @local_data_path = Pathname.new(File.expand_path(opts[:local_data_path], @cwd))
      end

      @logger.debug("Effective local data path: #{@local_data_path}")

      # If we have a root path, load the ".vagrantplugins" file.
      if root_path
        plugins_file = root_path.join(".vagrantplugins")
        if plugins_file.file?
          @logger.info("Loading plugins file: #{plugins_file}")
          load plugins_file
        end
      end

      setup_local_data_path

      # Setup the default private key
      @default_private_key_path = @home_path.join("insecure_private_key")
      copy_insecure_private_key

      # Initialize localized plugins
      plugins = Vagrant::Plugin::Manager.instance.localize!(self)
      # Load any environment local plugins
      Vagrant::Plugin::Manager.instance.load_plugins(plugins)

      # Initialize globalize plugins
      plugins = Vagrant::Plugin::Manager.instance.globalize!
      # Load any global plugins
      Vagrant::Plugin::Manager.instance.load_plugins(plugins)

      plugins = process_configured_plugins

      # Call the hooks that does not require configurations to be loaded
      # by using a "clean" action runner
      hook(:environment_plugins_loaded, runner: Action::Runner.new(env: self))

      # Call the environment load hooks
      hook(:environment_load, runner: Action::Runner.new(env: self))
    end

    # Return a human-friendly string for pretty printed or inspected
    # instances.
    #
    # @return [String]
    def inspect
      "#<#{self.class}: #{@cwd}>".encode('external')
    end

    # Action runner for executing actions in the context of this environment.
    #
    # @return [Action::Runner]
    def action_runner
      @action_runner ||= Action::Runner.new do
        {
          action_runner:  action_runner,
          box_collection: boxes,
          hook:           method(:hook),
          host:           host,
          machine_index:  machine_index,
          gems_path:      gems_path,
          home_path:      home_path,
          root_path:      root_path,
          tmp_path:       tmp_path,
          ui:             @ui,
          env:            self
        }
      end
    end

    # Returns a list of machines that this environment is currently
    # managing that physically have been created.
    #
    # An "active" machine is a machine that Vagrant manages that has
    # been created. The machine itself may be in any state such as running,
    # suspended, etc. but if a machine is "active" then it exists.
    #
    # Note that the machines in this array may no longer be present in
    # the Vagrantfile of this environment. In this case the machine can
    # be considered an "orphan." Determining which machines are orphan
    # and which aren't is not currently a supported feature, but will
    # be in a future version.
    #
    # @return [Array<String, Symbol>]
    def active_machines
      # We have no active machines if we have no data path
      return [] if !@local_data_path

      machine_folder = @local_data_path.join("machines")

      # If the machine folder is not a directory then we just return
      # an empty array since no active machines exist.
      return [] if !machine_folder.directory?

      # Traverse the machines folder accumulate a result
      result = []

      machine_folder.children(true).each do |name_folder|
        # If this isn't a directory then it isn't a machine
        next if !name_folder.directory?

        name = name_folder.basename.to_s.to_sym
        name_folder.children(true).each do |provider_folder|
          # If this isn't a directory then it isn't a provider
          next if !provider_folder.directory?

          # If this machine doesn't have an ID, then ignore
          next if !provider_folder.join("id").file?

          provider = provider_folder.basename.to_s.to_sym
          result << [name, provider]
        end
      end

      # Return the results
      result
    end

    # This creates a new batch action, yielding it, and then running it
    # once the block is called.
    #
    # This handles the case where batch actions are disabled by the
    # VAGRANT_NO_PARALLEL environmental variable.
    def batch(parallel=true)
      parallel = false if ENV["VAGRANT_NO_PARALLEL"]

      @batch_lock.synchronize do
        BatchAction.new(parallel).tap do |b|
          # Yield it so that the caller can setup actions
          yield b

          # And run it!
          b.run
        end
      end
    end

    # Makes a call to the CLI with the given arguments as if they
    # came from the real command line (sometimes they do!). An example:
    #
    #     env.cli("package", "--vagrantfile", "Vagrantfile")
    #
    def cli(*args)
      CLI.new(args.flatten, self).execute
    end

    # This returns the provider name for the default provider for this
    # environment.
    #
    # @return [Symbol] Name of the default provider.
    def default_provider(**opts)
      opts[:exclude]       = Set.new(opts[:exclude]) if opts[:exclude]
      opts[:force_default] = true if !opts.key?(:force_default)
      opts[:check_usable] = true if !opts.key?(:check_usable)

      # Implement the algorithm from
      # https://www.vagrantup.com/docs/providers/basic_usage.html#default-provider
      # with additional steps 2.5 and 3.5 from
      # https://bugzilla.redhat.com/show_bug.cgi?id=1444492
      # to allow system-configured provider priorities.
      #
      # 1. The --provider flag on a vagrant up is chosen above all else, if it is
      #    present.
      #
      # (Step 1 is done by the caller; this method is only called if --provider
      # wasn't given.)
      #
      # 2. If the VAGRANT_DEFAULT_PROVIDER environmental variable is set, it
      #    takes next priority and will be the provider chosen.

      default = ENV["VAGRANT_DEFAULT_PROVIDER"].to_s
      if default.empty?
        default = nil
      else
        default = default.to_sym
        @logger.debug("Default provider: `#{default}`")
      end

      # If we're forcing the default, just short-circuit and return
      # that (the default behavior)
      if default && opts[:force_default]
        @logger.debug("Using forced default provider: `#{default}`")
        return default
      end

      # Determine the config to use to look for provider definitions. By
      # default it is the global but if we're targeting a specific machine,
      # then look there.
      root_config = vagrantfile.config
      if opts[:machine]
        machine_info = vagrantfile.machine_config(opts[:machine], nil, nil, nil)
        root_config = machine_info[:config]
      end

      # Get the list of providers within our configuration, in order.
      config = root_config.vm.__providers

      # Get the list of usable providers with their internally-declared
      # priorities.
      usable = []
      Vagrant.plugin("2").manager.providers.each do |key, data|
        impl  = data[0]
        popts = data[1]

        # Skip excluded providers
        next if opts[:exclude] && opts[:exclude].include?(key)

        # Skip providers that can't be defaulted, unless they're in our
        # config, in which case someone made our decision for us.
        if !config.include?(key)
          next if popts.key?(:defaultable) && !popts[:defaultable]
        end

        # Skip providers that aren't usable.
        next if opts[:check_usable] && !impl.usable?(false)

        # Each provider sets its own priority, defaulting to 5 so we can trust
        # it's always set.
        usable << [popts[:priority], key]
      end
      @logger.debug("Initial usable provider list: #{usable}")

      # Sort the usable providers by priority. Higher numbers are higher
      # priority, otherwise alpha sort.
      usable = usable.sort {|a, b| a[0] == b[0] ? a[1] <=> b[1] : b[0] <=> a[0]}
                      .map {|prio, key| key}
      @logger.debug("Priority sorted usable provider list: #{usable}")

      # If we're not forcing the default, but it's usable and hasn't been
      # otherwise excluded, return it now.
      if usable.include?(default)
        @logger.debug("Using default provider `#{default}` as it was found in usable list.")
        return default
      end

      # 2.5. Vagrant will go through all of the config.vm.provider calls in the
      #      Vagrantfile and try each in order. It will choose the first
      #      provider that is usable and listed in VAGRANT_PREFERRED_PROVIDERS.

      preferred = ENV.fetch('VAGRANT_PREFERRED_PROVIDERS', '')
                     .split(',')
                     .map {|s| s.strip}
                     .select {|s| !s.empty?}
                     .map {|s| s.to_sym}
      @logger.debug("Preferred provider list: #{preferred}")

      config.each do |key|
        if usable.include?(key) && preferred.include?(key)
          @logger.debug("Using preferred provider `#{key}` detected in configuration and usable.")
          return key
        end
      end

      # 3. Vagrant will go through all of the config.vm.provider calls in the
      #    Vagrantfile and try each in order. It will choose the first provider
      #    that is usable. For example, if you configure Hyper-V, it will never
      #    be chosen on Mac this way. It must be both configured and usable.

      config.each do |key|
        if usable.include?(key)
          @logger.debug("Using provider `#{key}` detected in configuration and usable.")
          return key
        end
      end

      # 3.5. Vagrant will go through VAGRANT_PREFERRED_PROVIDERS and find the
      #      first plugin that reports it is usable.

      preferred.each do |key|
        if usable.include?(key)
          @logger.debug("Using preferred provider `#{key}` found in usable list.")
          return key
        end
      end

      # 4. Vagrant will go through all installed provider plugins (including the
      #    ones that come with Vagrant), and find the first plugin that reports
      #    it is usable. There is a priority system here: systems that are known
      #    better have a higher priority than systems that are worse. For
      #    example, if you have the VMware provider installed, it will always
      #    take priority over VirtualBox.

      if !usable.empty?
        @logger.debug("Using provider `#{usable[0]}` as it is the highest priority in the usable list.")
        return usable[0]
      end

      # 5. If Vagrant still has not found any usable providers, it will error.

      # No providers available is a critical error for Vagrant.
      raise Errors::NoDefaultProvider
    end

    # Returns whether or not we know how to install the provider with
    # the given name.
    #
    # @return [Boolean]
    def can_install_provider?(name)
      host.capability?(provider_install_key(name))
    end

    # Installs the provider with the given name.
    #
    # This will raise an exception if we don't know how to install the
    # provider with the given name. You should guard this call with
    # `can_install_provider?` for added safety.
    #
    # An exception will be raised if there are any failures installing
    # the provider.
    def install_provider(name)
      host.capability(provider_install_key(name))
    end

    # Returns the collection of boxes for the environment.
    #
    # @return [BoxCollection]
    def boxes
      @_boxes ||= BoxCollection.new(
        boxes_path,
        hook: method(:hook),
        temp_dir_root: tmp_path)
    end

    # Returns the {Config::Loader} that can be used to load Vagrantfiles
    # given the settings of this environment.
    #
    # @return [Config::Loader]
    def config_loader
      return @config_loader if @config_loader

      home_vagrantfile = nil
      root_vagrantfile = nil
      home_vagrantfile = find_vagrantfile(home_path) if home_path
      if root_path
        root_vagrantfile = find_vagrantfile(root_path, @vagrantfile_name)
      end

      @config_loader = Config::Loader.new(
        Config::VERSIONS, Config::VERSIONS_ORDER)
      @config_loader.set(:home, home_vagrantfile) if home_vagrantfile
      @config_loader.set(:root, root_vagrantfile) if root_vagrantfile
      @config_loader
    end

    # Loads another environment for the given Vagrantfile, sharing as much
    # useful state from this Environment as possible (such as UI and paths).
    # Any initialization options can be overidden using the opts hash.
    #
    # @param [String] vagrantfile Path to a Vagrantfile
    # @return [Environment]
    def environment(vagrantfile, **opts)
      path = File.expand_path(vagrantfile, root_path)
      file = File.basename(path)
      path = File.dirname(path)

      Util::SilenceWarnings.silence! do
        Environment.new({
          child:     true,
          cwd:       path,
          home_path: home_path,
          ui_class:  ui_class,
          vagrantfile_name: file,
        }.merge(opts))
      end
    end

    # This defines a hook point where plugin action hooks that are registered
    # against the given name will be run in the context of this environment.
    #
    # @param [Symbol] name Name of the hook.
    # @param [Action::Runner] action_runner A custom action runner for running hooks.
    def hook(name, opts=nil)
      @logger.info("Running hook: #{name}")

      opts ||= {}
      opts[:callable] ||= Action::Builder.new
      opts[:runner] ||= action_runner
      opts[:action_name] = name
      opts[:env] = self
      opts.delete(:runner).run(opts.delete(:callable), opts)
    end

    # Returns the host object associated with this environment.
    #
    # @return [Class]
    def host
      return @host if defined?(@host)

      # Determine the host class to use. ":detect" is an old Vagrant config
      # that shouldn't be valid anymore, but we respect it here by assuming
      # its old behavior. No need to deprecate this because I thin it is
      # fairly harmless.
      host_klass = vagrantfile.config.vagrant.host
      host_klass = nil if host_klass == :detect

      begin
        @host = Host.new(
          host_klass,
          Vagrant.plugin("2").manager.hosts,
          Vagrant.plugin("2").manager.host_capabilities,
          self)
      rescue Errors::CapabilityHostNotDetected
        # If the auto-detect failed, then we create a brand new host
        # with no capabilities and use that. This should almost never happen
        # since Vagrant works on most host OS's now, so this is a "slow path"
        klass = Class.new(Vagrant.plugin("2", :host)) do
          def detect?(env); true; end
        end

        hosts     = { generic: [klass, nil] }
        host_caps = {}

        @host = Host.new(:generic, hosts, host_caps, self)
      rescue Errors::CapabilityHostExplicitNotDetected => e
        raise Errors::HostExplicitNotDetected, e.extra_data
      end
    end

    # This acquires a process-level lock with the given name.
    #
    # The lock file is held within the data directory of this environment,
    # so make sure that all environments that are locking are sharing
    # the same data directory.
    #
    # This will raise Errors::EnvironmentLockedError if the lock can't
    # be obtained.
    #
    # @param [String] name Name of the lock, since multiple locks can
    #   be held at one time.
    def lock(name="global", **opts)
      f = nil

      # If we don't have a block, then locking is useless, so ignore it
      return if !block_given?

      # This allows multiple locks in the same process to be nested
      return yield if @locks[name] || opts[:noop]

      # The path to this lock
      lock_path = data_dir.join("lock.#{name}.lock")

      @logger.debug("Attempting to acquire process-lock: #{name}")
      lock("dotlock", noop: name == "dotlock", retry: true) do
        f = File.open(lock_path, "w+")
      end

      # The file locking fails only if it returns "false." If it
      # succeeds it returns a 0, so we must explicitly check for
      # the proper error case.
      while f.flock(File::LOCK_EX | File::LOCK_NB) === false
        @logger.warn("Process-lock in use: #{name}")

        if !opts[:retry]
          raise Errors::EnvironmentLockedError,
            name: name
        end

        sleep 0.2
      end

      @logger.info("Acquired process lock: #{name}")

      result = nil
      begin
        # Mark that we have a lock
        @locks[name] = true

        result = yield
      ensure
        # We need to make sure that no matter what this is always
        # reset to false so we don't think we have a lock when we
        # actually don't.
        @locks.delete(name)
        @logger.info("Released process lock: #{name}")
      end

      # Clean up the lock file, this requires another lock
      if name != "dotlock"
        lock("dotlock", retry: true) do
          f.close
          begin
            File.delete(lock_path)
          rescue
            @logger.error(
              "Failed to delete lock file #{lock_path} - some other thread " +
              "might be trying to acquire it. ignoring this error")
          end
        end
      end

      # Return the result
      return result
    ensure
      begin
        f.close if f
      rescue IOError
      end
    end

    # This executes the push with the given name, raising any exceptions that
    # occur.
    #
    # Precondition: the push is not nil and exists.
    def push(name)
      @logger.info("Getting push: #{name}")

      name = name.to_sym

      pushes = self.vagrantfile.config.push.__compiled_pushes
      if !pushes.key?(name)
        raise Vagrant::Errors::PushStrategyNotDefined,
          name: name,
          pushes: pushes.keys
      end

      strategy, config = pushes[name]
      push_registry = Vagrant.plugin("2").manager.pushes
      klass, _ = push_registry.get(strategy)
      if klass.nil?
        raise Vagrant::Errors::PushStrategyNotLoaded,
          name: strategy,
          pushes: push_registry.keys
      end

      klass.new(self, config).push
    end

    # The list of pushes defined in this Vagrantfile.
    #
    # @return [Array<Symbol>]
    def pushes
      self.vagrantfile.config.push.__compiled_pushes.keys
    end

    # This returns a machine with the proper provider for this environment.
    # The machine named by `name` must be in this environment.
    #
    # @param [Symbol] name Name of the machine (as configured in the
    #   Vagrantfile).
    # @param [Symbol] provider The provider that this machine should be
    #   backed by.
    # @param [Boolean] refresh If true, then if there is a cached version
    #   it is reloaded.
    # @return [Machine]
    def machine(name, provider, refresh=false)
      @logger.info("Getting machine: #{name} (#{provider})")

      # Compose the cache key of the name and provider, and return from
      # the cache if we have that.
      cache_key = [name, provider]
      @machines ||= {}
      if refresh
        @logger.info("Refreshing machine (busting cache): #{name} (#{provider})")
        @machines.delete(cache_key)
      end

      if @machines.key?(cache_key)
        @logger.info("Returning cached machine: #{name} (#{provider})")
        return @machines[cache_key]
      end

      @logger.info("Uncached load of machine.")

      # Determine the machine data directory and pass it to the machine.
      machine_data_path = @local_data_path.join(
        "machines/#{name}/#{provider}")

      # Create the machine and cache it for future calls. This will also
      # return the machine from this method.
      @machines[cache_key] = vagrantfile.machine(
        name, provider, boxes, machine_data_path, self)
    end

    # The {MachineIndex} to store information about the machines.
    #
    # @return [MachineIndex]
    def machine_index
      @machine_index ||= MachineIndex.new(@machine_index_dir)
    end

    # This returns a list of the configured machines for this environment.
    # Each of the names returned by this method is valid to be used with
    # the {#machine} method.
    #
    # @return [Array<Symbol>] Configured machine names.
    def machine_names
      vagrantfile.machine_names
    end

    # This returns the name of the machine that is the "primary." In the
    # case of  a single-machine environment, this is just the single machine
    # name. In the case of a multi-machine environment, then this can
    # potentially be nil if no primary machine is specified.
    #
    # @return [Symbol]
    def primary_machine_name
      vagrantfile.primary_machine_name
    end

    # The root path is the path where the top-most (loaded last)
    # Vagrantfile resides. It can be considered the project root for
    # this environment.
    #
    # @return [String]
    def root_path
      return @root_path if defined?(@root_path)

      root_finder = lambda do |path|
        # Note: To remain compatible with Ruby 1.8, we have to use
        # a `find` here instead of an `each`.
        vf = find_vagrantfile(path, @vagrantfile_name)
        return path if vf
        return nil if path.root? || !File.exist?(path)
        root_finder.call(path.parent)
      end

      @root_path = root_finder.call(cwd)
    end

    # Unload the environment, running completion hooks. The environment
    # should not be used after this (but CAN be, technically). It is
    # recommended to always immediately set the variable to `nil` after
    # running this so you can't accidentally run any more methods. Example:
    #
    #     env.unload
    #     env = nil
    #
    def unload
      hook(:environment_unload)
    end

    # Represents the default Vagrantfile, or the Vagrantfile that is
    # in the working directory or a parent of the working directory
    # of this environment.
    #
    # The existence of this function is primarily a convenience. There
    # is nothing stopping you from instantiating your own {Vagrantfile}
    # and loading machines in any way you see fit. Typical behavior of
    # Vagrant, however, loads this Vagrantfile.
    #
    # This Vagrantfile is comprised of two major sources: the Vagrantfile
    # in the user's home directory as well as the "root" Vagrantfile or
    # the Vagrantfile in the working directory (or parent).
    #
    # @return [Vagrantfile]
    def vagrantfile
      @vagrantfile ||= Vagrantfile.new(config_loader, [:home, :root])
    end

    #---------------------------------------------------------------
    # Load Methods
    #---------------------------------------------------------------

    # This sets the `@home_path` variable properly.
    #
    # @return [Pathname]
    def setup_home_path
      @logger.info("Home path: #{@home_path}")

      # Setup the list of child directories that need to be created if they
      # don't already exist.
      dirs    = [
        @home_path,
        @home_path.join("rgloader"),
        @boxes_path,
        @data_dir,
        @gems_path,
        @tmp_path,
        @machine_index_dir,
      ]

      # Go through each required directory, creating it if it doesn't exist
      dirs.each do |dir|
        next if File.directory?(dir)

        begin
          @logger.info("Creating: #{dir}")
          FileUtils.mkdir_p(dir)
        rescue Errno::EACCES
          raise Errors::HomeDirectoryNotAccessible, home_path: @home_path.to_s
        end
      end

      # Attempt to write into the home directory to verify we can
      begin
        # Append a random suffix to avoid race conditions if Vagrant
        # is running in parallel with other Vagrant processes.
        suffix = (0...32).map { (65 + rand(26)).chr }.join
        path   = @home_path.join("perm_test_#{suffix}")
        path.open("w") do |f|
          f.write("hello")
        end
        path.unlink
      rescue Errno::EACCES
        raise Errors::HomeDirectoryNotAccessible, home_path: @home_path.to_s
      end

      # Create the version file that we use to track the structure of
      # the home directory. If we have an old version, we need to explicitly
      # upgrade it. Otherwise, we just mark that its the current version.
      version_file = @home_path.join("setup_version")
      if version_file.file?
        version = version_file.read.chomp
        if version > CURRENT_SETUP_VERSION
          raise Errors::HomeDirectoryLaterVersion
        end

        case version
        when CURRENT_SETUP_VERSION
          # We're already good, at the latest version.
        when "1.1"
          # We need to update our directory structure
          upgrade_home_path_v1_1

          # Delete the version file so we put our latest version in
          version_file.delete
        else
          raise Errors::HomeDirectoryUnknownVersion,
            path: @home_path.to_s,
            version: version
        end
      end

      if !version_file.file?
        @logger.debug(
          "Creating home directory version file: #{CURRENT_SETUP_VERSION}")
        version_file.open("w") do |f|
          f.write(CURRENT_SETUP_VERSION)
        end
      end

      # Create the rgloader/loader file so we can use encoded files.
      loader_file = @home_path.join("rgloader", "loader.rb")
      if !loader_file.file?
        source_loader = Vagrant.source_root.join("templates/rgloader.rb")
        FileUtils.cp(source_loader.to_s, loader_file.to_s)
      end
    end

    # This creates the local data directory and show an error if it
    # couldn't properly be created.
    def setup_local_data_path(force=false)
      if @local_data_path.nil?
        @logger.warn("No local data path is set. Local data cannot be stored.")
        return
      end

      @logger.info("Local data path: #{@local_data_path}")

      # If the local data path is a file, then we are probably seeing an
      # old (V1) "dotfile." In this case, we upgrade it. The upgrade process
      # will remove the old data file if it is successful.
      if @local_data_path.file?
        upgrade_v1_dotfile(@local_data_path)
      end

      # If we don't have a root path, we don't setup anything
      return if !force && root_path.nil?

      begin
        @logger.debug("Creating: #{@local_data_path}")
        FileUtils.mkdir_p(@local_data_path)
        # Create the rgloader/loader file so we can use encoded files.
        loader_file = @local_data_path.join("rgloader", "loader.rb")
        if !loader_file.file?
          source_loader = Vagrant.source_root.join("templates/rgloader.rb")
          FileUtils.mkdir_p(@local_data_path.join("rgloader").to_s)
          FileUtils.cp(source_loader.to_s, loader_file.to_s)
        end
      rescue Errno::EACCES
        raise Errors::LocalDataDirectoryNotAccessible,
          local_data_path: @local_data_path.to_s
      end
    end

    protected

    # Attempt to guess the configured provider in use. Will fallback
    # to the default provider if an explicit provider name is not
    # provided. This can be pretty error prone, but is used during
    # initial environment setup to allow loading plugins so it doesn't
    # need to be perfect
    #
    # @return [String]
    def guess_provider
      gp = nil
      ARGV.each_with_index do |val, idx|
        if val.start_with?("--provider=")
          gp = val.split("=", 2).last
          break
        elsif val == "--provider"
          gp = ARGV[idx+1]
          break
        end
      end
      return gp.to_sym if gp
      begin
        default_provider
      rescue Errors::NoDefaultProvider
        # if a provider cannot be determined just return nil
        nil
      end
    end

    # Load any configuration provided by guests defined within
    # the Vagrantfile to pull plugin information they may have
    # defined.
    def find_configured_plugins
      plugins = []
      provider = guess_provider
      vagrantfile.machine_names.each do |mname|
        ldp = @local_data_path.join("machines/#{mname}/#{provider}") if @local_data_path
        plugins << vagrantfile.machine_config(mname, guess_provider, boxes, ldp, false)[:config]
      end
      result = plugins.reverse.inject(Vagrant::Util::HashWithIndifferentAccess.new) do |memo, val|
        Vagrant::Util::DeepMerge.deep_merge(memo, val.vagrant.plugins)
      end
      Vagrant::Util::DeepMerge.deep_merge(result, vagrantfile.config.vagrant.plugins)
    end

    # Check for any local plugins defined within the Vagrantfile. If
    # found, validate they are available. If they are not available,
    # request to install them, or raise an exception
    #
    # @return [Hash] plugin list for loading
    def process_configured_plugins
      return if !Vagrant.plugins_enabled?
      errors = vagrantfile.config.vagrant.validate(nil)
      if !errors["vagrant"].empty?
        raise Errors::ConfigInvalid,
          errors: Util::TemplateRenderer.render(
            "config/validation_failed",
            errors: errors)
      end
      # Check if defined plugins are installed
      installed = Plugin::Manager.instance.installed_plugins
      needs_install = []
      config_plugins = find_configured_plugins
      config_plugins.each do |name, info|
        if !installed[name]
          needs_install << name
        end
      end
      if !needs_install.empty?
        ui.warn(I18n.t("vagrant.plugins.local.uninstalled_plugins",
          plugins: needs_install.sort.join(", ")))
        if !Vagrant.auto_install_local_plugins?
          answer = nil
          until ["y", "n"].include?(answer)
            answer = ui.ask(I18n.t("vagrant.plugins.local.request_plugin_install") + " [N]: ")
            answer = answer.strip.downcase
            answer = "n" if answer.to_s.empty?
          end
          if answer == "n"
            raise Errors::PluginMissingLocalError,
              plugins: needs_install.sort.join(", ")
          end
        end
        needs_install.each do |name|
          pconfig = Util::HashWithIndifferentAccess.new(config_plugins[name])
          ui.info(I18n.t("vagrant.commands.plugin.installing", name: name))

          options = {sources: Vagrant::Bundler::DEFAULT_GEM_SOURCES.dup, env_local: true}
          options[:sources] = pconfig[:sources] if pconfig[:sources]
          options[:require] = pconfig[:entry_point] if pconfig[:entry_point]
          options[:version] = pconfig[:version] if pconfig[:version]

          spec = Plugin::Manager.instance.install_plugin(name, **options)

          ui.info(I18n.t("vagrant.commands.plugin.installed",
            name: spec.name, version: spec.version.to_s))
        end
        ui.info("\n")
        # Force halt after installation and require command to be run again. This
        # will proper load any new locally installed plugins which are now available.
        ui.warn(I18n.t("vagrant.plugins.local.install_rerun_command"))
        exit(-1)
      end
      if Vagrant::Plugin::Manager.instance.local_file
        Vagrant::Plugin::Manager.instance.local_file.installed_plugins
      else
        {}
      end
    end

    # This method copies the private key into the home directory if it
    # doesn't already exist.
    #
    # This must be done because `ssh` requires that the key is chmod
    # 0600 or more, but if Vagrant is installed as a separate user, then the
    # effective uid won't be able to read the key. So the key is copied
    # to the home directory and chmod 0600.
    def copy_insecure_private_key
      if !@default_private_key_path.exist?
        @logger.info("Copying private key to home directory")

        source      = File.expand_path("keys/vagrant", Vagrant.source_root)
        destination = @default_private_key_path

        begin
          FileUtils.cp(source, destination)
        rescue Errno::EACCES
          raise Errors::CopyPrivateKeyFailed,
            source: source,
            destination: destination
        end
      end

      if !Util::Platform.windows?
        # On Windows, permissions don't matter as much, so don't worry
        # about doing chmod.
        if Util::FileMode.from_octal(@default_private_key_path.stat.mode) < "600"
          @logger.info("Changing permissions on private key to 0600")
          @default_private_key_path.chmod(0600)
        end
      end
    end

    # Finds the Vagrantfile in the given directory.
    #
    # @param [Pathname] path Path to search in.
    # @return [Pathname]
    def find_vagrantfile(search_path, filenames=nil)
      filenames ||= ["Vagrantfile", "vagrantfile"]
      filenames.each do |vagrantfile|
        current_path = search_path.join(vagrantfile)
        return current_path if current_path.file?
      end

      nil
    end

    # Returns the key used for the host capability for provider installs
    # of the given name.
    def provider_install_key(name)
      "provider_install_#{name}".to_sym
    end

    # This upgrades a home directory that was in the v1.1 format to the
    # v1.5 format. It will raise exceptions if anything fails.
    def upgrade_home_path_v1_1
      if !ENV["VAGRANT_UPGRADE_SILENT_1_5"]
        @ui.ask(I18n.t("vagrant.upgrading_home_path_v1_5"))
      end

      collection = BoxCollection.new(
        @home_path.join("boxes"), temp_dir_root: tmp_path)
      collection.upgrade_v1_1_v1_5
    end

    # This upgrades a Vagrant 1.0.x "dotfile" to the new V2 format.
    #
    # This is a destructive process. Once the upgrade is complete, the
    # old dotfile is removed, and the environment becomes incompatible for
    # Vagrant 1.0 environments.
    #
    # @param [Pathname] path The path to the dotfile
    def upgrade_v1_dotfile(path)
      @logger.info("Upgrading V1 dotfile to V2 directory structure...")

      # First, verify the file isn't empty. If it is an empty file, we
      # just delete it and go on with life.
      contents = path.read.strip
      if contents.strip == ""
        @logger.info("V1 dotfile was empty. Removing and moving on.")
        path.delete
        return
      end

      # Otherwise, verify there is valid JSON in here since a Vagrant
      # environment would always ensure valid JSON. This is a sanity check
      # to make sure we don't nuke a dotfile that is not ours...
      @logger.debug("Attempting to parse JSON of V1 file")
      json_data = nil
      begin
        json_data = JSON.parse(contents)
        @logger.debug("JSON parsed successfully. Things are okay.")
      rescue JSON::ParserError
        # The file could've been tampered with since Vagrant 1.0.x is
        # supposed to ensure that the contents are valid JSON. Show an error.
        raise Errors::DotfileUpgradeJSONError,
          state_file: path.to_s
      end

      # Alright, let's upgrade this guy to the new structure. Start by
      # backing up the old dotfile.
      backup_file = path.dirname.join(".vagrant.v1.#{Time.now.to_i}")
      @logger.info("Renaming old dotfile to: #{backup_file}")
      path.rename(backup_file)

      # Now, we create the actual local data directory. This should succeed
      # this time since we renamed the old conflicting V1.
      setup_local_data_path(true)

      if json_data["active"]
        @logger.debug("Upgrading to V2 style for each active VM")
        json_data["active"].each do |name, id|
          @logger.info("Upgrading dotfile: #{name} (#{id})")

          # Create the machine configuration directory
          directory = @local_data_path.join("machines/#{name}/virtualbox")
          FileUtils.mkdir_p(directory)

          # Write the ID file
          directory.join("id").open("w+") do |f|
            f.write(id)
          end
        end
      end

      # Upgrade complete! Let the user know
      @ui.info(I18n.t("vagrant.general.upgraded_v1_dotfile",
                      backup_path: backup_file.to_s))
    end
  end
end
