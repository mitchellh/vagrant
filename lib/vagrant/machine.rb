require_relative "util/ssh"
require_relative "action/builtin/mixin_synced_folders"

require "digest/md5"
require "thread"

require "log4r"

module Vagrant
  # This represents a machine that Vagrant manages. This provides a singular
  # API for querying the state and making state changes to the machine, which
  # is backed by any sort of provider (VirtualBox, VMware, etc.).
  class Machine
    extend Vagrant::Action::Builtin::MixinSyncedFolders

    # The box that is backing this machine.
    #
    # @return [Box]
    attr_accessor :box

    # Configuration for the machine.
    #
    # @return [Object]
    attr_accessor :config

    # Directory where machine-specific data can be stored.
    #
    # @return [Pathname]
    attr_reader :data_dir

    # The environment that this machine is a part of.
    #
    # @return [Environment]
    attr_reader :env

    # ID of the machine. This ID comes from the provider and is not
    # guaranteed to be of any particular format except that it is
    # a string.
    #
    # @return [String]
    attr_reader :id

    # Name of the machine. This is assigned by the Vagrantfile.
    #
    # @return [Symbol]
    attr_reader :name

    # The provider backing this machine.
    #
    # @return [Object]
    attr_reader :provider

    # The provider-specific configuration for this machine.
    #
    # @return [Object]
    attr_accessor :provider_config

    # The name of the provider.
    #
    # @return [Symbol]
    attr_reader :provider_name

    # The options given to the provider when registering the plugin.
    #
    # @return [Hash]
    attr_reader :provider_options

    # The triggers with machine specific configuration applied
    #
    # @return [Vagrant::Plugin::V2::Trigger]
    attr_reader :triggers

    # The UI for outputting in the scope of this machine.
    #
    # @return [UI]
    attr_reader :ui

    # The Vagrantfile that this machine is attached to.
    #
    # @return [Vagrantfile]
    attr_reader :vagrantfile

    # Initialize a new machine.
    #
    # @param [String] name Name of the virtual machine.
    # @param [Class] provider The provider backing this machine. This is
    #   currently expected to be a V1 `provider` plugin.
    # @param [Object] provider_config The provider-specific configuration for
    #   this machine.
    # @param [Hash] provider_options The provider-specific options from the
    #   plugin definition.
    # @param [Object] config The configuration for this machine.
    # @param [Pathname] data_dir The directory where machine-specific data
    #   can be stored. This directory is ensured to exist.
    # @param [Box] box The box that is backing this virtual machine.
    # @param [Environment] env The environment that this machine is a
    #   part of.
    def initialize(name, provider_name, provider_cls, provider_config, provider_options, config, data_dir, box, env, vagrantfile, base=false)
      @logger = Log4r::Logger.new("vagrant::machine")
      @logger.info("Initializing machine: #{name}")
      @logger.info("  - Provider: #{provider_cls}")
      @logger.info("  - Box: #{box}")
      @logger.info("  - Data dir: #{data_dir}")

      @box             = box
      @config          = config
      @data_dir        = data_dir
      @env             = env
      @vagrantfile     = vagrantfile
      @guest           = Guest.new(
        self,
        Vagrant.plugin("2").manager.guests,
        Vagrant.plugin("2").manager.guest_capabilities)
      @name            = name
      @provider_config = provider_config
      @provider_name   = provider_name
      @provider_options = provider_options
      @ui              = Vagrant::UI::Prefixed.new(@env.ui, @name)
      @ui_mutex        = Mutex.new
      @state_mutex     = Mutex.new
      @triggers        = Vagrant::Plugin::V2::Trigger.new(@env, @config.trigger, self, @ui)

      @__config_ssh = nil

      # Read the ID, which is usually in local storage
      @id = nil

      # XXX: This is temporary. This will be removed very soon.
      if base
        @id = name

        # For base setups, we don't want to insert the key
        @config.ssh.insert_key = false
      else
        reload
      end

      # Keep track of where our UUID should be placed
      @index_uuid_file = nil
      @index_uuid_file = @data_dir.join("index_uuid") if @data_dir

      # Initializes the provider last so that it has access to all the
      # state we setup on this machine.
      @provider = provider_cls.new(self)
      @provider._initialize(@provider_name, self)

      # If we're using WinRM, we eager load the plugin because of
      # GH-3390
      if @config.vm.communicator == :winrm
        @logger.debug("Eager loading WinRM communicator to avoid GH-3390")
        communicate
      end

      # If the ID is the special not created ID, then set our ID to
      # nil so that we destroy all our data.
      if state.id == MachineState::NOT_CREATED_ID
        self.id = nil
      end

      # Output a bunch of information about this machine in
      # machine-readable format in case someone is listening.
      @ui.machine("metadata", "provider", provider_name)
    end

    # This calls an action on the provider. The provider may or may not
    # actually implement the action.
    #
    # @param [Symbol] name Name of the action to run.
    # @param [Hash] extra_env This data will be passed into the action runner
    #   as extra data set on the environment hash for the middleware
    #   runner.
    def action(name, opts=nil)
      @logger.info("Calling action: #{name} on provider #{@provider}")

      opts ||= {}

      # Determine whether we lock or not
      lock = true
      lock = opts.delete(:lock) if opts.key?(:lock)

      # Extra env keys are the remaining opts
      extra_env = opts.dup
      # An environment is required for triggers to function properly. This is
      # passed in specifically for the `#Action::Warden` class triggers. We call it
      # `:trigger_env` instead of `env` in case it collides with an existing environment
      extra_env[:trigger_env] = @env

      check_cwd # Warns the UI if the machine was last used on a different dir

      # Create a deterministic ID for this machine
      vf = nil
      vf = @env.vagrantfile_name[0] if @env.vagrantfile_name
      id = Digest::MD5.hexdigest(
        "#{@env.root_path}#{vf}#{@env.local_data_path}#{@name}")

      # We only lock if we're not executing an SSH action. In the future
      # we will want to do more fine-grained unlocking in actions themselves
      # but for a 1.6.2 release this will work.
      locker = Proc.new { |*args, &block| block.call }
      locker = @env.method(:lock) if lock && !name.to_s.start_with?("ssh")

      # Lock this machine for the duration of this action
      return_env = locker.call("machine-action-#{id}") do
        # Get the callable from the provider.
        callable = @provider.action(name)

        # If this action doesn't exist on the provider, then an exception
        # must be raised.
        if callable.nil?
          raise Errors::UnimplementedProviderAction,
            action: name,
            provider: @provider.to_s
        end

        # Call the action
        ui.machine("action", name.to_s, "start")
        action_result = action_raw(name, callable, extra_env)
        ui.machine("action", name.to_s, "end")
        action_result
      end
      # preserve returning environment after machine action runs
      return return_env
    rescue Errors::EnvironmentLockedError
      raise Errors::MachineActionLockedError,
        action: name,
        name: @name
    end

    # This calls a raw callable in the proper context of the machine using
    # the middleware stack.
    #
    # @param [Symbol] name Name of the action
    # @param [Proc] callable
    # @param [Hash] extra_env Extra env for the action env.
    # @return [Hash] The resulting env
    def action_raw(name, callable, extra_env={})
      if !extra_env.is_a?(Hash)
        extra_env = {}
      end

      # Run the action with the action runner on the environment
      env = {ui: @ui}.merge(extra_env).merge(
        raw_action_name: name,
        action_name: "machine_action_#{name}".to_sym,
        machine: self,
        machine_action: name
      )
      @env.action_runner.run(callable, env)
    end

    # Returns a communication object for executing commands on the remote
    # machine. Note that the _exact_ semantics of this are up to the
    # communication provider itself. Despite this, the semantics are expected
    # to be consistent across operating systems. For example, all linux-based
    # systems should have similar communication (usually a shell). All
    # Windows systems should have similar communication as well. Therefore,
    # prior to communicating with the machine, users of this method are
    # expected to check the guest OS to determine their behavior.
    #
    # This method will _always_ return some valid communication object.
    # The `ready?` API can be used on the object to check if communication
    # is actually ready.
    #
    # @return [Object]
    def communicate
      if !@communicator
        requested  = @config.vm.communicator
        requested ||= :ssh
        klass = Vagrant.plugin("2").manager.communicators[requested]
        raise Errors::CommunicatorNotFound, comm: requested.to_s if !klass
        @communicator = klass.new(self)
      end
      @communicator
    end


    # Returns a guest implementation for this machine. The guest implementation
    # knows how to do guest-OS specific tasks, such as configuring networks,
    # mounting folders, etc.
    #
    # @return [Guest]
    def guest
      raise Errors::MachineGuestNotReady if !communicate.ready?
      @guest.detect! if !@guest.ready?
      @guest
    end

    # This sets the unique ID associated with this machine. This will
    # persist this ID so that in the future Vagrant will be able to find
    # this machine again. The unique ID must be absolutely unique to the
    # virtual machine, and can be used by providers for finding the
    # actual machine associated with this instance.
    #
    # **WARNING:** Only providers should ever use this method.
    #
    # @param [String] value The ID.
    def id=(value)
      @logger.info("New machine ID: #{value.inspect}")

      id_file = nil
      if @data_dir
        # The file that will store the id if we have one. This allows the
        # ID to persist across Vagrant runs. Also, store the UUID for the
        # machine index.
        id_file = @data_dir.join("id")
      end

      if value
        if id_file
          # Write the "id" file with the id given.
          id_file.open("w+") do |f|
            f.write(value)
          end
        end

        if uid_file
          # Write the user id that created this machine
          uid_file.open("w+") do |f|
            f.write(Process.uid.to_s)
          end
        end

        # If we don't have a UUID, then create one
        if index_uuid.nil?
          # Create the index entry and save it
          entry = MachineIndex::Entry.new
          entry.local_data_path = @env.local_data_path
          entry.name = @name.to_s
          entry.provider = @provider_name.to_s
          entry.state = "preparing"
          entry.vagrantfile_path = @env.root_path
          entry.vagrantfile_name = @env.vagrantfile_name

          if @box
            entry.extra_data["box"] = {
              "name"     => @box.name,
              "provider" => @box.provider.to_s,
              "version"  => @box.version.to_s,
            }
          end

          entry = @env.machine_index.set(entry)
          @env.machine_index.release(entry)

          # Store our UUID so we can access it later
          if @index_uuid_file
            @index_uuid_file.open("w+") do |f|
              f.write(entry.id)
            end
          end
        end
      else
        # Delete the file, since the machine is now destroyed
        id_file.delete if id_file && id_file.file?
        uid_file.delete if uid_file && uid_file.file?

        # If we have a UUID associated with the index, remove it
        uuid = index_uuid
        if uuid
          entry = @env.machine_index.get(uuid)
          @env.machine_index.delete(entry) if entry
        end

        if @data_dir
          # Delete the entire data directory contents since all state
          # associated with the VM is now gone.
          @data_dir.children.each do |child|
            begin
              child.rmtree
            rescue Errno::EACCES
              @logger.info("EACCESS deleting file: #{child}")
            end
          end
        end
      end

      # Store the ID locally
      @id = value.nil? ? nil : value.to_s

      # Notify the provider that the ID changed in case it needs to do
      # any accounting from it.
      @provider.machine_id_changed
    end

    # Returns the UUID associated with this machine in the machine
    # index. We only have a UUID if an ID has been set.
    #
    # @return [String] UUID or nil if we don't have one yet.
    def index_uuid
      return nil if !@index_uuid_file
      return @index_uuid_file.read.chomp if @index_uuid_file.file?
      return nil
    end

    # This returns a clean inspect value so that printing the value via
    # a pretty print (`p`) results in a readable value.
    #
    # @return [String]
    def inspect
      "#<#{self.class}: #{@name} (#{@provider.class})>"
    end

    # This reloads the ID of the underlying machine.
    def reload
      old_id = @id
      @id = nil

      if @data_dir
        # Read the id file from the data directory if it exists as the
        # ID for the pre-existing physical representation of this machine.
        id_file = @data_dir.join("id")
        id_content = id_file.read.strip if id_file.file?
        if !id_content.to_s.empty?
          @id = id_content
        end
      end

      if @id != old_id && @provider
        # It changed, notify the provider
        @provider.machine_id_changed
      end

      @id
    end

    def ssh_config
      if !@__config_ssh
        requested  = @config.vm.communicator
        requested ||= :ssh
        @__config_ssh = @config.vm.get_communicator_config(requested, @config)

        if @__config_ssh.nil?
          @__config_ssh = @config.ssh
        end
      end
      @__config_ssh
    end

    # This returns the SSH info for accessing this machine. This SSH info
    # is queried from the underlying provider. This method returns `nil` if
    # the machine is not ready for SSH communication.
    #
    # The structure of the resulting hash is guaranteed to contain the
    # following structure, although it may return other keys as well
    # not documented here:
    #
    #     {
    #       host: "1.2.3.4",
    #       port: "22",
    #       username: "mitchellh",
    #       private_key_path: "/path/to/my/key"
    #     }
    #
    # Note that Vagrant makes no guarantee that this info works or is
    # correct. This is simply the data that the provider gives us or that
    # is configured via a Vagrantfile. It is still possible after this
    # point when attempting to connect via SSH to get authentication
    # errors.
    #
    # @return [Hash] SSH information.
    def ssh_info
      # First, ask the provider for their information. If the provider
      # returns nil, then the machine is simply not ready for SSH, and
      # we return nil as well.
      info = @provider.ssh_info
      return nil if info.nil?

      # Delete out the nil entries.
      info.dup.each do |key, value|
        info.delete(key) if value.nil?
      end

      # We set the defaults
      info[:host] ||= @config.ssh.default.host
      info[:port] ||= @config.ssh.default.port
      info[:private_key_path] ||= @config.ssh.default.private_key_path
      info[:keys_only] ||= @config.ssh.default.keys_only
      info[:verify_host_key] ||= @config.ssh.default.verify_host_key
      info[:username] ||= @config.ssh.default.username
      info[:remote_user] ||= @config.ssh.default.remote_user
      info[:compression] ||= @config.ssh.default.compression
      info[:dsa_authentication] ||= @config.ssh.default.dsa_authentication
      info[:extra_args] ||= @config.ssh.default.extra_args
      info[:config] ||= @config.ssh.default.config

      # We set overrides if they are set. These take precedence over
      # provider-returned data.
      info[:host] = ssh_config().host if  ssh_config().host
      info[:port] = ssh_config().port if  ssh_config().port
      info[:keys_only] = ssh_config().keys_only
      info[:verify_host_key] = ssh_config().verify_host_key
      info[:compression] = ssh_config().compression
      info[:dsa_authentication] = ssh_config().dsa_authentication
      info[:username] = ssh_config().username if  ssh_config().username
      info[:password] = ssh_config().password if  ssh_config().password
      info[:remote_user] = ssh_config().remote_user if  ssh_config().remote_user
      info[:extra_args] = ssh_config().extra_args if  ssh_config().extra_args
      info[:config] = ssh_config().config if  ssh_config().config

      # We also set some fields that are purely controlled by Vagrant
      info[:forward_agent] = ssh_config().forward_agent
      info[:forward_x11] = ssh_config().forward_x11
      info[:forward_env] = ssh_config().forward_env
      info[:connect_timeout] = ssh_config().connect_timeout

      info[:ssh_command] = ssh_config().ssh_command if  ssh_config().ssh_command

      # Add in provided proxy command config
      info[:proxy_command] = ssh_config().proxy_command if  ssh_config().proxy_command

      # Set the private key path. If a specific private key is given in
      # the Vagrantfile we set that. Otherwise, we use the default (insecure)
      # private key, but only if the provider didn't give us one.
      if !info[:private_key_path] && !info[:password]
        if ssh_config().private_key_path
          info[:private_key_path] = ssh_config().private_key_path
        elsif info[:keys_only]
          info[:private_key_path] = @env.default_private_key_path
        end
      end

      # If we have a private key in our data dir, then use that
      if @data_dir && !ssh_config().private_key_path
        data_private_key = @data_dir.join("private_key")
        if data_private_key.file?
          info[:private_key_path] = [data_private_key.to_s]
        end
      end

      # Setup the keys
      info[:private_key_path] ||= []
      info[:private_key_path] = Array(info[:private_key_path])

      # Expand the private key path relative to the root path
      info[:private_key_path].map! do |path|
        File.expand_path(path, @env.root_path)
      end

      # Check that the private key permissions are valid
      info[:private_key_path].each do |path|
        key_path = Pathname.new(path)
        if key_path.exist?
          Vagrant::Util::SSH.check_key_permissions(key_path)
        end
      end

      # Return the final compiled SSH info data
      info
    end

    # Returns the state of this machine. The state is queried from the
    # backing provider, so it can be any arbitrary symbol.
    #
    # @return [MachineState]
    def state
      result = @provider.state
      raise Errors::MachineStateInvalid if !result.is_a?(MachineState)

      # Update our state cache if we have a UUID and an entry in the
      # master index.
      uuid = index_uuid
      if uuid
        # active_machines provides access to query this info on each machine
        # from a different thread, ensure multiple machines do not access
        # the locked entry simultaneously as this triggers a locked machine
        # exception.
        @state_mutex.synchronize do
          entry = @env.machine_index.get(uuid)
          if entry
            entry.state = result.short_description
            @env.machine_index.set(entry)
            @env.machine_index.release(entry)
          end
        end
      end

      result
    end

    # Returns the state of this machine. The state is queried from the
    # backing provider, so it can be any arbitrary symbol.
    #
    # @param [Symbol] state of machine
    # @return [Entry] entry of recovered machine
    def recover_machine(state)
      entry = @env.machine_index.get(index_uuid)
      if entry
        @env.machine_index.release(entry)
        return entry
      end

      entry = MachineIndex::Entry.new(id=index_uuid, {})
      entry.local_data_path = @env.local_data_path
      entry.name = @name.to_s
      entry.provider = @provider_name.to_s
      entry.state = state
      entry.vagrantfile_path = @env.root_path
      entry.vagrantfile_name = @env.vagrantfile_name

      if @box
        entry.extra_data["box"] = {
          "name"     => @box.name,
          "provider" => @box.provider.to_s,
          "version"  => @box.version.to_s,
        }
      end

      @state_mutex.synchronize do
        entry = @env.machine_index.recover(entry)
        @env.machine_index.release(entry)
      end
      return entry
    end

    # Returns the user ID that created this machine. This is specific to
    # the host machine that this was created on.
    #
    # @return [String]
    def uid
      path = uid_file
      return nil if !path
      return nil if !path.file?
      return uid_file.read.chomp
    end

    # Temporarily changes the machine UI. This is useful if you want
    # to execute an {#action} with a different UI.
    def with_ui(ui)
      @ui_mutex.synchronize do
        begin
          old_ui = @ui
          @ui    = ui
          yield
        ensure
          @ui = old_ui
        end
      end
    end

    # This returns the set of shared folders that should be done for
    # this machine. It returns the folders in a hash keyed by the
    # implementation class for the synced folders.
    #
    # @return [Hash<Symbol, Hash<String, Hash>>]
    def synced_folders
      self.class.synced_folders(self)
    end

    protected

    # Returns the path to the file that stores the UID.
    def uid_file
      return nil if !@data_dir
      @data_dir.join("creator_uid")
    end

    # Checks the current directory for a given machine
    # and displays a warning if that machine has moved
    # from its previous location on disk. If the machine
    # has moved, it prints a warning to the user.
    def check_cwd
      desired_encoding = @env.root_path.to_s.encoding
      vagrant_cwd_filepath = @data_dir.join('vagrant_cwd')
      vagrant_cwd = if File.exist?(vagrant_cwd_filepath)
                      File.read(vagrant_cwd_filepath,
                        external_encoding: desired_encoding
                      ).chomp
                    end

      if !File.identical?(vagrant_cwd.to_s, @env.root_path.to_s)
        if vagrant_cwd
          ui.warn(I18n.t(
            'vagrant.moved_cwd',
            old_wd:     "#{vagrant_cwd}",
            current_wd: "#{@env.root_path.to_s}"))
        end
        File.write(vagrant_cwd_filepath, @env.root_path.to_s,
          external_encoding: desired_encoding
        )
      end
    end
  end
end
