require "pathname"
require "securerandom"
require "set"

require "vagrant"
require "vagrant/action/builtin/mixin_synced_folders"
require "vagrant/config/v2/util"
require "vagrant/util/platform"
require "vagrant/util/presence"
require "vagrant/util/experimental"
require "vagrant/util/map_command_options"

require File.expand_path("../vm_provisioner", __FILE__)
require File.expand_path("../vm_subvm", __FILE__)
require File.expand_path("../disk", __FILE__)
require File.expand_path("../cloud_init", __FILE__)

module VagrantPlugins
  module Kernel_V2
    class VMConfig < Vagrant.plugin("2", :config)
      include Vagrant::Util::Presence

      DEFAULT_VM_NAME = :default

      attr_accessor :allowed_synced_folder_types
      attr_accessor :allow_fstab_modification
      attr_accessor :allow_hosts_modification
      attr_accessor :base_mac
      attr_accessor :base_address
      attr_accessor :boot_timeout
      attr_accessor :box
      attr_accessor :ignore_box_vagrantfile
      attr_accessor :box_check_update
      attr_accessor :box_url
      attr_accessor :box_server_url
      attr_accessor :box_version
      attr_accessor :box_download_ca_cert
      attr_accessor :box_download_ca_path
      attr_accessor :box_download_checksum
      attr_accessor :box_download_checksum_type
      attr_accessor :box_download_client_cert
      attr_accessor :box_download_insecure
      attr_accessor :box_download_location_trusted
      attr_accessor :box_download_options
      attr_accessor :communicator
      attr_accessor :graceful_halt_timeout
      attr_accessor :guest
      attr_accessor :hostname
      attr_accessor :post_up_message
      attr_accessor :failed_up_message
      attr_accessor :usable_port_range
      attr_reader :provisioners
      attr_reader :disks
      attr_reader :cloud_init_configs
      attr_reader :box_extra_download_options

      # This is an experimental feature that isn't public yet.
      attr_accessor :clone

      def initialize
        @logger = Log4r::Logger.new("vagrant::config::vm")

        @allowed_synced_folder_types   = UNSET_VALUE
        @allow_fstab_modification      = UNSET_VALUE
        @base_mac                      = UNSET_VALUE
        @base_address                  = UNSET_VALUE
        @boot_timeout                  = UNSET_VALUE
        @box                           = UNSET_VALUE
        @ignore_box_vagrantfile        = UNSET_VALUE
        @box_check_update              = UNSET_VALUE
        @box_download_ca_cert          = UNSET_VALUE
        @box_download_ca_path          = UNSET_VALUE
        @box_download_checksum         = UNSET_VALUE
        @box_download_checksum_type    = UNSET_VALUE
        @box_download_client_cert      = UNSET_VALUE
        @box_download_insecure         = UNSET_VALUE
        @box_download_location_trusted = UNSET_VALUE
        @box_download_options          = UNSET_VALUE
        @box_extra_download_options    = UNSET_VALUE
        @box_url                       = UNSET_VALUE
        @box_version                   = UNSET_VALUE
        @allow_hosts_modification      = UNSET_VALUE
        @clone                         = UNSET_VALUE
        @communicator                  = UNSET_VALUE
        @graceful_halt_timeout         = UNSET_VALUE
        @guest                         = UNSET_VALUE
        @hostname                      = UNSET_VALUE
        @post_up_message               = UNSET_VALUE
        @failed_up_message             = UNSET_VALUE
        @provisioners                  = []
        @disks                         = []
        @cloud_init_configs            = []
        @usable_port_range             = UNSET_VALUE

        # Internal state
        @__compiled_provider_configs   = {}
        @__defined_vm_keys             = []
        @__defined_vms                 = {}
        @__finalized                   = false
        @__networks                    = {}
        @__providers                   = {}
        @__provider_order              = []
        @__provider_overrides          = {}
        @__synced_folders              = {}
      end

      # This was from V1, but we just kept it here as an alias for hostname
      # because too many people mess this up.
      def host_name=(value)
        @hostname = value
      end

      # Custom merge method since some keys here are merged differently.
      def merge(other)
        super.tap do |result|
          other_networks = other.instance_variable_get(:@__networks)

          result.instance_variable_set(:@__networks, @__networks.merge(other_networks))

          # Merge defined VMs by first merging the defined VM keys,
          # preserving the order in which they were defined.
          other_defined_vm_keys = other.instance_variable_get(:@__defined_vm_keys)
          other_defined_vm_keys -= @__defined_vm_keys
          new_defined_vm_keys   = @__defined_vm_keys + other_defined_vm_keys

          # Merge the actual defined VMs.
          other_defined_vms = other.instance_variable_get(:@__defined_vms)
          new_defined_vms   = {}

          @__defined_vms.each do |key, subvm|
            new_defined_vms[key] = subvm.clone
          end

          other_defined_vms.each do |key, subvm|
            if !new_defined_vms.key?(key)
              new_defined_vms[key] = subvm.clone
            else
              new_defined_vms[key].config_procs.concat(subvm.config_procs)
              new_defined_vms[key].options.merge!(subvm.options)
            end
          end

          # Merge defined disks
          other_disks = other.instance_variable_get(:@disks)
          new_disks   = []
          @disks.each do |p|
            other_p = other_disks.find { |o| p.id == o.id }
            if other_p
              # there is an override. take it.
              other_p.config = p.config.merge(other_p.config)

              # Remove duplicate disk config from other
              p = other_p
              other_disks.delete(other_p)
            end

            # there is an override, merge it into the
            new_disks << p.dup
          end
          other_disks.each do |p|
            new_disks << p.dup
          end
          result.instance_variable_set(:@disks, new_disks)

          # Merge defined cloud_init_configs
          other_cloud_init_configs = other.instance_variable_get(:@cloud_init_configs)
          new_cloud_init_configs   = []
          @cloud_init_configs.each do |p|
            other_p = other_cloud_init_configs.find { |o| p.id == o.id }
            if other_p
              # there is an override. take it.
              other_p.config = p.config.merge(other_p.config)

              # Remove duplicate disk config from other
              p = other_p
              other_cloud_init_configs.delete(other_p)
            end

            # there is an override, merge it into the
            new_cloud_init_configs << p.dup
          end
          other_cloud_init_configs.each do |p|
            new_cloud_init_configs << p.dup
          end
          result.instance_variable_set(:@cloud_init_configs, new_cloud_init_configs)

          # Merge the providers by prepending any configuration blocks we
          # have for providers onto the new configuration.
          other_providers = other.instance_variable_get(:@__providers)
          new_providers   = @__providers.dup
          other_providers.each do |key, blocks|
            new_providers[key] ||= []
            new_providers[key] += blocks
          end

          # Merge the provider ordering. Anything defined in our CURRENT
          # scope is before anything else.
          other_order = other.instance_variable_get(:@__provider_order)
          new_order   = @__provider_order.dup
          new_order   = (new_order + other_order).uniq

          # Merge the provider overrides by appending them...
          other_overrides = other.instance_variable_get(:@__provider_overrides)
          new_overrides   = @__provider_overrides.dup
          other_overrides.each do |key, blocks|
            new_overrides[key] ||= []
            new_overrides[key] += blocks
          end

          # Merge provisioners. First we deal with overrides and making
          # sure the ordering is good there. Then we merge them.
          new_provs   = []
          other_provs = other.provisioners.dup
          @provisioners.each do |p|
            other_p = other_provs.find { |o| p.id == o.id }
            if other_p
              # There is an override. Take it.
              other_p.config = p.config.merge(other_p.config)
              other_p.run    ||= p.run
              next if !other_p.preserve_order

              # We're preserving order, delete from other
              p = other_p
              other_provs.delete(other_p)
            end

            # There is an override, merge it into the
            new_provs << p.dup
          end
          other_provs.each do |p|
            new_provs << p.dup
          end
          result.instance_variable_set(:@provisioners, new_provs)

          # Merge synced folders.
          other_folders = other.instance_variable_get(:@__synced_folders)
          new_folders = {}
          @__synced_folders.each do |key, value|
            new_folders[key] = value.dup
          end

          other_folders.each do |id, options|
            new_folders[id] ||= {}
            new_folders[id].merge!(options)
          end

          result.instance_variable_set(:@__defined_vm_keys, new_defined_vm_keys)
          result.instance_variable_set(:@__defined_vms, new_defined_vms)
          result.instance_variable_set(:@__providers, new_providers)
          result.instance_variable_set(:@__provider_order, new_order)
          result.instance_variable_set(:@__provider_overrides, new_overrides)
          result.instance_variable_set(:@__synced_folders, new_folders)
        end
      end

      # Defines a synced folder pair. This pair of folders will be synced
      # to/from the machine. Note that if the machine you're using doesn't
      # support multi-directional syncing (perhaps an rsync backed synced
      # folder) then the host is always synced to the guest but guest data
      # may not be synced back to the host.
      #
      # @param [String] hostpath Path to the host folder to share. If this
      #   is a relative path, it is relative to the location of the
      #   Vagrantfile.
      # @param [String] guestpath Path on the guest to mount the shared
      #   folder.
      # @param [Hash] options Additional options.
      def synced_folder(hostpath, guestpath, options=nil)
        if Vagrant::Util::Platform.windows?
          # On Windows, Ruby just uses normal '/' for path seps, so
          # just replace normal Windows style seps with Unix ones.
          hostpath = hostpath.to_s.gsub("\\", "/")
        end

        if guestpath.is_a?(Hash)
          options = guestpath
          guestpath = nil
        end

        options ||= {}

        if options[:nfs]
          options[:type] = :nfs
          options.delete(:nfs)
        end

        if options.has_key?(:name)
          synced_folder_name = options.delete(:name)
        else
          synced_folder_name = guestpath
        end

        options[:guestpath] = guestpath.to_s.gsub(/\/$/, '') if guestpath
        options[:hostpath]  = hostpath
        options[:disabled]  = false if !options.key?(:disabled)
        options = (@__synced_folders[options[:guestpath]] || {}).
          merge(options.dup)

        # Make sure the type is a symbol
        options[:type] = options[:type].to_sym if options[:type]

        @__synced_folders[synced_folder_name] = options
      end

      # Define a way to access the machine via a network. This exposes a
      # high-level abstraction for networking that may not directly map
      # 1-to-1 for every provider. For example, AWS has no equivalent to
      # "port forwarding." But most providers will attempt to implement this
      # in a way that behaves similarly.
      #
      # `type` can be one of:
      #
      #   * `:forwarded_port` - A port that is accessible via localhost
      #     that forwards into the machine.
      #   * `:private_network` - The machine gets an IP that is not directly
      #     publicly accessible, but ideally accessible from this machine.
      #   * `:public_network` - The machine gets an IP on a shared network.
      #
      # @param [Symbol] type Type of network
      # @param [Hash] options Options for the network.
      def network(type, **options)
        options = options.dup
        options[:protocol] ||= "tcp"

        # Convert to symbol to allow strings
        type = type.to_sym

        if !options[:id]
          default_id = nil

          if type == :forwarded_port
            # For forwarded ports, set the default ID to be the
            # concat of host_ip, proto and host_port. This would ensure Vagrant
            # caters for port forwarding in an IP aliased environment where
            # different host IP addresses are to be listened on the same port.
            default_id = "#{options[:host_ip]}#{options[:protocol]}#{options[:host]}"
          end

          options[:id] = default_id || SecureRandom.uuid
        end

        # Scope the ID by type so that different types can share IDs
        id      = options[:id]
        id      = "#{type}-#{id}"

        # Merge in the previous settings if we have them.
        if @__networks.key?(id)
          options = @__networks[id][1].merge(options)
        end

        # Merge in the latest settings and set the internal state
        @__networks[id] = [type.to_sym, options]
      end

      # Configures a provider for this VM.
      #
      # @param [Symbol] name The name of the provider.
      def provider(name, &block)
        name = name.to_sym
        @__providers[name] ||= []
        @__provider_overrides[name] ||= []

        # Add the provider to the ordering list
        @__provider_order << name

        if block_given?
          @__providers[name] << block if block_given?

          # If this block takes two arguments, then we curry it and store
          # the configuration override for use later.
          if block.arity == 2
            @__provider_overrides[name] << block.curry[Vagrant::Config::V2::DummyConfig.new]
          end
        end
      end

      def provision(name, **options, &block)
        type = name
        if options.key?(:type)
          type = options.delete(:type)
        else
          name = nil
        end

        if options.key?(:id)
          puts "Setting `id` on a provisioner is deprecated. Please use the"
          puts "new syntax of `config.vm.provision \"name\", type: \"type\""
          puts "where \"name\" is the replacement for `id`. This will be"
          puts "fully removed in Vagrant 1.8."

          name = id
        end

        prov = nil
        if name
          name = name.to_sym
          prov = @provisioners.find { |p| p.name == name }
        end

        if !prov
          if options.key?(:before)
            before = options.delete(:before)
          end
          if options.key?(:after)
            after = options.delete(:after)
          end

          if Vagrant::Util::Experimental.feature_enabled?("dependency_provisioners")
            opts = {before: before, after: after}
            prov = VagrantConfigProvisioner.new(name, type.to_sym, **opts)
          else
            prov = VagrantConfigProvisioner.new(name, type.to_sym)
          end
          @provisioners << prov
        end

        prov.preserve_order = !!options.delete(:preserve_order) if \
          options.key?(:preserve_order)
        prov.run = options.delete(:run) if options.key?(:run)
        prov.communicator_required = options.delete(:communicator_required) if options.key?(:communicator_required)

        prov.add_config(**options, &block)
        nil
      end

      def defined_vms
        @__defined_vms
      end

      # This returns the keys of the sub-vms in the order they were
      # defined.
      def defined_vm_keys
        @__defined_vm_keys
      end

      def define(name, options=nil, &block)
        name = name.to_sym
        options ||= {}
        options = options.dup
        options[:config_version] ||= "2"

        # Add the name to the array of VM keys. This array is used to
        # preserve the order in which VMs are defined.
        @__defined_vm_keys << name if !@__defined_vm_keys.include?(name)

        # Add the SubVM to the hash of defined VMs
        if !@__defined_vms[name]
          @__defined_vms[name] = VagrantConfigSubVM.new
        end

        @__defined_vms[name].options.merge!(options)
        @__defined_vms[name].config_procs << [options[:config_version], block] if block
      end

      # Stores disk config options from Vagrantfile
      #
      # @param [Symbol] type
      # @param [Hash]   options
      # @param [Block]  block
      def disk(type, **options, &block)
        disk_config = VagrantConfigDisk.new(type)

        # Remove provider__option options before set_options, otherwise will
        # show up as missing setting
        # Extract provider hash options as well
        provider_options = {}
        options.delete_if do |p,o|
          if o.is_a?(Hash) || p.to_s.include?("__")
            provider_options[p] = o
            true
          end
        end

        disk_config.set_options(options)

        # Add provider config
        disk_config.add_provider_config(**provider_options, &block)

        if !Vagrant::Util::Experimental.feature_enabled?("disks")
          @logger.warn("Disk config defined, but experimental feature is not enabled. To use this feature, enable it with the experimental flag `disks`. Disk will not be added to internal config, and will be ignored.")
          return
        end

        @disks << disk_config
      end

      # Stores config options for cloud_init
      #
      # @param [Symbol] type
      # @param [Hash]   options
      # @param [Block]  block
      def cloud_init(type=nil, **options, &block)
        type = type.to_sym if type

        cloud_init_config = VagrantConfigCloudInit.new(type)

        if block_given?
          block.call(cloud_init_config, VagrantConfigCloudInit)
        else
          # config is hash
          cloud_init_config.set_options(options)
        end

        if !Vagrant::Util::Experimental.feature_enabled?("cloud_init")
          @logger.warn("cloud_init config defined, but experimental feature is not enabled. To use this feature, enable it with the experimental flag `cloud_init`. cloud_init config will not be added to internal config, and will be ignored.")
          return
        end

        @cloud_init_configs << cloud_init_config
      end

      #-------------------------------------------------------------------
      # Internal methods, don't call these.
      #-------------------------------------------------------------------

      def finalize!
        # Defaults
        @allowed_synced_folder_types = nil if @allowed_synced_folder_types == UNSET_VALUE
        @base_mac = nil if @base_mac == UNSET_VALUE
        @base_address = nil if @base_address == UNSET_VALUE
        @boot_timeout = 300 if @boot_timeout == UNSET_VALUE
        @box = nil if @box == UNSET_VALUE
        @ignore_box_vagrantfile = false if @ignore_box_vagrantfile == UNSET_VALUE

        if @box_check_update == UNSET_VALUE
          @box_check_update = !present?(ENV["VAGRANT_BOX_UPDATE_CHECK_DISABLE"])
        end

        @box_download_ca_cert = nil if @box_download_ca_cert == UNSET_VALUE
        @box_download_ca_path = nil if @box_download_ca_path == UNSET_VALUE
        @box_download_checksum = nil if @box_download_checksum == UNSET_VALUE
        @box_download_checksum_type = nil if @box_download_checksum_type == UNSET_VALUE
        @box_download_client_cert = nil if @box_download_client_cert == UNSET_VALUE
        @box_download_insecure = false if @box_download_insecure == UNSET_VALUE
        @box_download_location_trusted = false if @box_download_location_trusted == UNSET_VALUE
        @box_url = nil if @box_url == UNSET_VALUE
        @box_version = nil if @box_version == UNSET_VALUE
        @box_download_options = {} if @box_download_options == UNSET_VALUE
        @box_extra_download_options = Vagrant::Util::MapCommandOptions.map_to_command_options(@box_download_options)
        @allow_hosts_modification = true if @allow_hosts_modification == UNSET_VALUE
        @clone = nil if @clone == UNSET_VALUE
        @communicator = nil if @communicator == UNSET_VALUE
        @graceful_halt_timeout = 60 if @graceful_halt_timeout == UNSET_VALUE
        @guest = nil if @guest == UNSET_VALUE
        @hostname = nil if @hostname == UNSET_VALUE
        @hostname = @hostname.to_s if @hostname
        @post_up_message = "" if @post_up_message == UNSET_VALUE
        @failed_up_message = "" if @failed_up_message == UNSET_VALUE

        if @usable_port_range == UNSET_VALUE
          @usable_port_range = (2200..2250)
        end

        if @allowed_synced_folder_types
          @allowed_synced_folder_types = Array(@allowed_synced_folder_types).map(&:to_sym)
        end

        # Make sure that the download checksum is a string and that
        # the type is a symbol
        @box_download_checksum = "" if !@box_download_checksum
        if @box_download_checksum_type
          @box_download_checksum_type = @box_download_checksum_type.to_sym
        end

        # Make sure the box URL is an array if it is set
        @box_url = Array(@box_url) if @box_url

        # Set the communicator properly
        @communicator = @communicator.to_sym if @communicator

        # Set the guest properly
        @guest = @guest.to_sym if @guest

        # If we haven't defined a single VM, then we need to define a
        # default VM which just inherits the rest of the configuration.
        define(DEFAULT_VM_NAME) if defined_vm_keys.empty?

        # Make sure the SSH forwarding is added if it doesn't exist
        if @communicator == :winrm
          if !@__networks["forwarded_port-winrm"]
            network :forwarded_port,
              guest: 5985,
              host: 55985,
              host_ip: "127.0.0.1",
              id: "winrm",
              auto_correct: true
          end
          if !@__networks["forwarded_port-winrm-ssl"]
            network :forwarded_port,
              guest: 5986,
              host: 55986,
              host_ip: "127.0.0.1",
              id: "winrm-ssl",
              auto_correct: true
          end
        end
        # forward SSH ports regardless of communicator
        if !@__networks["forwarded_port-ssh"]
          network :forwarded_port,
            guest: 22,
            host: 2222,
            host_ip: "127.0.0.1",
            id: "ssh",
            auto_correct: true
        end

        # Clean up some network configurations
        @__networks.values.each do |type, opts|
          if type == :forwarded_port
            opts[:guest] = opts[:guest].to_i if opts[:guest]
            opts[:host] = opts[:host].to_i if opts[:host]
          end
        end

        # Compile all the provider configurations
        @__providers.each do |name, blocks|
          # If we don't have any configuration blocks, then ignore it
          next if blocks.empty?

          # Find the configuration class for this provider
          config_class = Vagrant.plugin("2").manager.provider_configs[name]
          config_class ||= Vagrant::Config::V2::DummyConfig

          # Load it up
          config = config_class.new

          begin
            blocks.each do |b|
              new_config = config_class.new
              b.call(new_config, Vagrant::Config::V2::DummyConfig.new)
              config = config.merge(new_config)
            end
          rescue Exception => e
            @logger.error("Vagrantfile load error: #{e.message}")
            @logger.error(e.inspect)
            @logger.error(e.message)
            @logger.error(e.backtrace.join("\n"))

            line = "(unknown)"
            if e.backtrace && e.backtrace[0]
              line = e.backtrace.first.slice(0, e.backtrace.first.rindex(':')).rpartition(':').last
            end

            raise Vagrant::Errors::VagrantfileLoadError,
              path: "<provider config: #{name}>",
              line: line,
              exception_class: e.class,
              message: e.message
          end

          config.finalize!

          # Store it for retrieval later
          @__compiled_provider_configs[name]   = config
        end

        # Finalize all the provisioners
        @provisioners.each do |p|
          p.config.finalize! if !p.invalid?
          p.run = p.run.to_sym if p.run
        end

        current_dir_shared = false
        @__synced_folders.each do |id, options|
          if options[:hostpath]  == '.'
            current_dir_shared = true
          end
        end

        @disks.each do |d|
          d.finalize!
        end

        @cloud_init_configs.each do |c|
          c.finalize!
        end

        if !current_dir_shared && !@__synced_folders["/vagrant"]
          synced_folder(".", "/vagrant")
        end

        # Flag that we finalized
        @__finalized = true
      end

      # This returns the compiled provider-specific configuration for the
      # given provider.
      #
      # @param [Symbol] name Name of the provider.
      def get_provider_config(name)
        raise "Must finalize first." if !@__finalized

        result = @__compiled_provider_configs[name]

        # If no compiled configuration was found, then we try to just
        # use the default configuration from the plugin.
        if !result
          config_class = Vagrant.plugin("2").manager.provider_configs[name]
          if config_class
            result = config_class.new
            result.finalize!
          end
        end

        return result
      end

      # This returns a list of VM configurations that are overrides
      # for this provider.
      #
      # @param [Symbol] name Name of the provider
      # @return [Array<Proc>]
      def get_provider_overrides(name)
        (@__provider_overrides[name] || []).map do |p|
          ["2", p]
        end
      end

      # This returns the list of networks configured.
      def networks
        @__networks.values
      end

      # This returns the list of synced folders
      def synced_folders
        @__synced_folders
      end

      def validate(machine, ignore_provider=nil)
        errors = _detected_errors

        if @allow_fstab_modification == UNSET_VALUE
          machine.synced_folders.types.each do |impl_name|
            inst = machine.synced_folders.type(impl_name)
            if inst.capability?(:default_fstab_modification) && inst.capability(:default_fstab_modification) == false
              @allow_fstab_modification = false
              break
            end
          end
          @allow_fstab_modification = true if @allow_fstab_modification == UNSET_VALUE
        end

        if !box && !clone && !machine.provider_options[:box_optional]
          errors << I18n.t("vagrant.config.vm.box_missing")
        end

        if box && clone
          errors << I18n.t("vagrant.config.vm.clone_and_box")
        end

        if box && box.empty?
          errors << I18n.t("vagrant.config.vm.box_empty", machine_name: machine.name)
        end

        errors << I18n.t("vagrant.config.vm.hostname_invalid_characters", name: machine.name) if \
          @hostname && @hostname !~ /^[a-z0-9][-.a-z0-9]*$/i

        if @box_version
          @box_version.to_s.split(",").each do |v|
            begin
              Gem::Requirement.new(v.strip)
            rescue Gem::Requirement::BadRequirementError
              errors << I18n.t(
                "vagrant.config.vm.bad_version", version: v)
            end
          end
        end

        if box_download_ca_cert
          path = Pathname.new(box_download_ca_cert).
            expand_path(machine.env.root_path)
          if !path.file?
            errors << I18n.t(
              "vagrant.config.vm.box_download_ca_cert_not_found",
              path: box_download_ca_cert)
          end
        end

        if box_download_ca_path
          path = Pathname.new(box_download_ca_path).
            expand_path(machine.env.root_path)
          if !path.directory?
            errors << I18n.t(
              "vagrant.config.vm.box_download_ca_path_not_found",
              path: box_download_ca_path)
          end
        end

        if box_download_checksum_type
          if box_download_checksum == ""
            errors << I18n.t("vagrant.config.vm.box_download_checksum_blank")
          end
        else
          if box_download_checksum != ""
            errors << I18n.t("vagrant.config.vm.box_download_checksum_notblank")
          end
        end

        if !box_download_options.is_a?(Hash)
          errors <<  I18n.t("vagrant.config.vm.box_download_options_type", type: box_download_options.class.to_s)
        end

        box_download_options.each do |k, v|
          # If the value is truthy and
          # if `box_extra_download_options` does not include the key
          # then the conversion to extra download options produced an error
          if v && !box_extra_download_options.include?("--#{k}")
            errors <<  I18n.t("vagrant.config.vm.box_download_options_not_converted", missing_key: k)
          end
        end

        used_guest_paths = Set.new
        @__synced_folders.each do |id, options|
          # If the shared folder is disabled then don't worry about validating it
          next if options[:disabled]

          guestpath = Pathname.new(options[:guestpath]) if options[:guestpath]
          hostpath  = Pathname.new(options[:hostpath]).expand_path(machine.env.root_path)

          if guestpath.to_s == "" && id.to_s == ""
            errors << I18n.t("vagrant.config.vm.shared_folder_requires_guestpath_or_name")
          elsif guestpath.to_s != ""
            if guestpath.relative? && guestpath.to_s !~ /^\w+:/
              errors << I18n.t("vagrant.config.vm.shared_folder_guestpath_relative",
                               path: options[:guestpath])
            else
              if used_guest_paths.include?(options[:guestpath])
                errors << I18n.t("vagrant.config.vm.shared_folder_guestpath_duplicate",
                                 path: options[:guestpath])
              end

              used_guest_paths.add(options[:guestpath])
            end
          end

          if !hostpath.directory? && !options[:create]
            errors << I18n.t("vagrant.config.vm.shared_folder_hostpath_missing",
                             path: options[:hostpath])
          end

          if options[:type] == :nfs && !options[:nfs__quiet]
            if options[:owner] || options[:group]
              # Owner/group don't work with NFS
              errors << I18n.t("vagrant.config.vm.shared_folder_nfs_owner_group",
                               path: options[:hostpath])
            end
          end

          if options[:mount_options] && !options[:mount_options].is_a?(Array)
            errors << I18n.t("vagrant.config.vm.shared_folder_mount_options_array")
          end

          if options[:type]
            plugins = Vagrant.plugin("2").manager.synced_folders
            impl_class = plugins[options[:type]]
            if !impl_class
              errors << I18n.t("vagrant.config.vm.shared_folder_invalid_option_type",
                              type: options[:type],
                              options: plugins.keys.join(', '))
            end
          end
        end

        # Validate networks
        has_fp_port_error = false
        fp_used = Set.new
        valid_network_types = [:forwarded_port, :private_network, :public_network]

        port_range=(1..65535)
        has_hostname_config = false
        networks.each do |type, options|
          if options[:hostname]
            if has_hostname_config
              errors << I18n.t("vagrant.config.vm.multiple_networks_set_hostname")
            end
            if options[:ip] == nil
              errors << I18n.t("vagrant.config.vm.network_with_hostname_must_set_ip")
            end
            has_hostname_config = true
          end
          if !valid_network_types.include?(type)
            errors << I18n.t("vagrant.config.vm.network_type_invalid",
                            type: type.to_s)
          end

          if type == :forwarded_port
            if !has_fp_port_error && (!options[:guest] || !options[:host])
              errors << I18n.t("vagrant.config.vm.network_fp_requires_ports")
              has_fp_port_error = true
            end

            if options[:host]
              key = "#{options[:host_ip]}#{options[:protocol]}#{options[:host]}"
              if fp_used.include?(key)
                errors << I18n.t("vagrant.config.vm.network_fp_host_not_unique",
                                host: options[:host].to_s,
                                protocol: options[:protocol].to_s)
              end

              fp_used.add(key)
            end

            if !port_range.include?(options[:host]) || !port_range.include?(options[:guest])
              errors << I18n.t("vagrant.config.vm.network_fp_invalid_port")
            end
          end

          if type == :private_network
            if options[:type] && options[:type].to_sym != :dhcp
              if !options[:ip]
                errors << I18n.t("vagrant.config.vm.network_ip_required")
              end
            end

            if options[:ip] && options[:ip].end_with?(".1") && (options[:type] || "").to_sym != :dhcp
              machine.ui.warn(I18n.t(
                "vagrant.config.vm.network_ip_ends_in_one"))
            end
          end
        end

        # Validate disks
        # Check if there is more than one primary disk defined and throw an error
        primary_disks = @disks.select { |d| d.primary && d.type == :disk }
        if primary_disks.size > 1
          errors << I18n.t("vagrant.config.vm.multiple_primary_disks_error",
                           name: machine.name)
        end

        disk_names = @disks.map { |d| d.name }
        duplicate_names = disk_names.find_all { |d| disk_names.count(d) > 1 }
        if duplicate_names.any?
          errors << I18n.t("vagrant.config.vm.multiple_disk_names_error",
                           name: machine.name,
                           disk_names: duplicate_names.uniq.join("\n"))
        end

        disk_files = @disks.map { |d| d.file }
        duplicate_files = disk_files.find_all { |d| d && disk_files.count(d) > 1 }
        if duplicate_files.any?
          errors << I18n.t("vagrant.config.vm.multiple_disk_files_error",
                           name: machine.name,
                           disk_files: duplicate_files.uniq.join("\n"))
        end

        @disks.each do |d|
          error = d.validate(machine)
          errors.concat(error) if !error.empty?
        end

        # Validate clout_init_configs
        @cloud_init_configs.each do |c|
          error = c.validate(machine)
          errors.concat error if !error.empty?
        end

        # We're done with VM level errors so prepare the section
        errors = { "vm" => errors }

        # Validate only the _active_ provider
        if machine.provider_config
          if !ignore_provider
            provider_errors = machine.provider_config.validate(machine)
            if provider_errors
              errors = Vagrant::Config::V2::Util.merge_errors(errors, provider_errors)
            end
          else
            machine.ui.warn(I18n.t("vagrant.config.vm.ignore_provider_config"))
          end
        end

        # Validate provisioners
        @provisioners.each do |vm_provisioner|
          if vm_provisioner.invalid?
            name = vm_provisioner.name.to_s
            name = vm_provisioner.type.to_s if name.empty?
            errors["vm"] << I18n.t("vagrant.config.vm.provisioner_not_found",
                                   name: name)
            next
          end

          provisioner_errors = vm_provisioner.validate(machine, @provisioners)
          if provisioner_errors
            errors = Vagrant::Config::V2::Util.merge_errors(errors, provisioner_errors)
          end

          if vm_provisioner.config
            provisioner_errors = vm_provisioner.config.validate(machine)
            if provisioner_errors
              errors = Vagrant::Config::V2::Util.merge_errors(errors, provisioner_errors)
            end
          end
        end

        # If running from the Windows Subsystem for Linux, validate that configured
        # hostpaths for synced folders are on DrvFs file systems, or the synced
        # folder implementation explicitly supports non-DrvFs file system types
        # within the WSL
        if Vagrant::Util::Platform.wsl?
          # Create a helper that will with the synced folders mixin
          # from the builtin action to get the correct implementation
          # to be used for each folder
          sf_helper = Class.new do
            include Vagrant::Action::Builtin::MixinSyncedFolders
          end.new
          folders = sf_helper.synced_folders(machine, config: self)
          folders.each do |impl_name, data|
            data.each do |_, fs|
              hostpath = File.expand_path(fs[:hostpath], machine.env.root_path)
              if !Vagrant::Util::Platform.wsl_drvfs_path?(hostpath)
                sf_klass = sf_helper.plugins[impl_name.to_sym].first
                if sf_klass.respond_to?(:wsl_allow_non_drvfs?) && sf_klass.wsl_allow_non_drvfs?
                  next
                end
                errors["vm"] << I18n.t("vagrant.config.vm.shared_folder_wsl_not_drvfs",
                  path: fs[:hostpath])
              end
            end
          end
        end

        # Validate sub-VMs if there are any
        @__defined_vms.each do |name, _|
          if name =~ /[\[\]\{\}\/]/
            errors["vm"] << I18n.t(
              "vagrant.config.vm.name_invalid",
              name: name)
          end
        end

        if ![TrueClass, FalseClass].include?(@allow_fstab_modification.class)
          errors["vm"] << I18n.t("vagrant.config.vm.config_type",
            option: "allow_fstab_modification", given: @allow_fstab_modification.class, required: "Boolean"
          )
        end

        if ![TrueClass, FalseClass].include?(@allow_hosts_modification.class)
          errors["vm"] << I18n.t("vagrant.config.vm.config_type",
            option: "allow_hosts_modification", given: @allow_hosts_modification.class, required: "Boolean"
          )
        end

        errors
      end

      def __providers
        @__provider_order
      end
    end
  end
end
