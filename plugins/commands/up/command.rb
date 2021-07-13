require 'optparse'
require 'set'

require "vagrant"

require File.expand_path("../start_mixins", __FILE__)

module VagrantPlugins
  module CommandUp
    class Command < Vagrant.plugin("2", :command)
      include StartMixins

      def self.synopsis
        "starts and provisions the vagrant environment or a single machine"
      end

      def execute
        options = {}
        options[:destroy_on_error] = true
        options[:install_provider] = true
        options[:parallel] = true
        options[:provision_ignore_sentinel] = false

        opts = OptionParser.new do |o|
          o.banner = "Usage: vagrant up [options] [name|id]"
          o.separator ""
          o.separator "Options:"
          o.separator ""

          build_start_options(o, options)

          o.on("--[no-]destroy-on-error",
               "Destroy machine if any fatal error happens (default to true)") do |destroy|
            options[:destroy_on_error] = destroy
          end

          o.on("--[no-]parallel",
               "Enable or disable parallelism if provider supports it") do |parallel|
            options[:parallel] = parallel
          end

          o.on("--provider PROVIDER", String,
               "Back the machine with a specific provider") do |provider|
            options[:provider] = provider
          end

          o.on("--[no-]install-provider",
               "If possible, install the provider if it isn't installed") do |p|
            options[:install_provider] = p
          end
        end

        # Parse the options
        argv = parse_options(opts)
        return if !argv

        # Validate the provisioners
        validate_provisioner_flags!(options, argv)

        # Go over each VM and bring it up
        @logger.debug("'Up' each target VM...")

        # Get the names of the machines we want to bring up
        names = argv
        if names.empty?
          autostart = false
          @env.vagrantfile.machine_names_and_options.each do |n, o|
            autostart = true if o.key?(:autostart)
            o[:autostart] = true if !o.key?(:autostart)
            names << n.to_s if o[:autostart]
          end

          # If we have an autostart key but no names, it means that
          # all machines are autostart: false and we don't start anything.
          names = nil if autostart && names.empty?
        end

        # Build up the batch job of what we'll do
        machines = []
        if names
          # To prevent vagrant from attempting to validate a global vms config
          # (which doesn't exist within the local dir) when attempting to
          # install a machines provider, this check below will disable the
          # install_providers function if a user gives us a machine id instead
          # of the machines name.
          machine_names = []
          with_target_vms(names, provider: options[:provider]){|m| machine_names << m.name }
          options[:install_provider] = false if !(machine_names - names).empty?

          # If we're installing providers, then do that. We don't
          # parallelize this step because it is likely the same provider
          # anyways.
          if options[:install_provider]
            install_providers(names, provider: options[:provider])
          end

          @env.batch(options[:parallel]) do |batch|
            with_target_vms(names, provider: options[:provider]) do |machine|
              @env.ui.info(I18n.t(
                "vagrant.commands.up.upping",
                name: machine.name,
                provider: machine.provider_name))

              machines << machine

              batch.action(machine, :up, options)
            end
          end
        end

        if machines.empty?
          @env.ui.info(I18n.t("vagrant.up_no_machines"))
          return 0
        end

        # Output the post-up messages that we have, if any
        machines.each do |m|
          next if !m.config.vm.post_up_message
          next if m.config.vm.post_up_message == ""

          # Add a newline to separate things.
          @env.ui.info("", prefix: false)

          m.ui.success(I18n.t(
            "vagrant.post_up_message",
            name: m.name.to_s,
            message: m.config.vm.post_up_message))
        end

        # Success, exit status 0
        0
      end

      protected

      def install_providers(names, provider: nil)
        # First create a set of all the providers we need to check for.
        # Most likely this will be a set of one.
        providers = Set.new
        with_target_vms(names, provider: provider) do |machine|
          # Check if we have this machine in the index
          entry    = @env.machine_index.get(machine.name.to_s)

          # Get the provider for this machine. This logic isn't completely
          # straightforward. If we have a forced provider, we always use
          # that no matter what. If we have an entry in the index (meaning
          # the machine may be created), we use that provider no matter
          # what since that will be used by the core. If we have none, then
          # we ask the Vagrant env what the default provider would be and use
          # that.
          #
          # Note that this logic is a bit redundant if we have "provider"
          # set but I think its probably cleaner to put this logic in one
          # place.
          p = provider
          p = entry.provider.to_sym if !p && entry
          p = @env.default_provider(
            machine: machine.name.to_sym, check_usable: false) if !p

          # Add it to the set
          providers.add(p)
        end

        # Go through and determine if we can install the providers
        providers.delete_if do |name|
          !@env.can_install_provider?(name)
        end

        # Install the providers if we have to
        providers.each do |name|
          # Find the provider. Ignore if we can't find it, this error
          # will pop up later in the process.
          parts = Vagrant.plugin("2").manager.providers[name]
          next if !parts

          # If the provider is already installed, then our work here is done
          cls = parts[0]
          next if cls.installed?

          # Some human-friendly output
          ui = Vagrant::UI::Prefixed.new(@env.ui, "")
          ui.output(I18n.t(
            "vagrant.installing_provider",
            provider: name.to_s))
          ui.detail(I18n.t("vagrant.installing_provider_detail"))

          # Install the provider
          @env.install_provider(name)
        end
      end
    end
  end
end
