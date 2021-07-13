require "ipaddr"
require "vagrant/action/builtin/mixin_synced_folders"

module VagrantPlugins
  module ProviderVirtualBox
    module Action
      class PrepareNFSSettings
        include Vagrant::Action::Builtin::MixinSyncedFolders
        include Vagrant::Util::Retryable

        def initialize(app, env)
          @app = app
          @logger = Log4r::Logger.new("vagrant::action::vm::nfs")
        end

        def call(env)
          @machine = env[:machine]

          @app.call(env)

          opts = {
            cached: !!env[:synced_folders_cached],
            config: env[:synced_folders_config],
            disable_usable_check: !!env[:test],
          }
          folders = synced_folders(env[:machine], **opts)

          if folders.key?(:nfs)
            @logger.info("Using NFS, preparing NFS settings by reading host IP and machine IP")
            add_ips_to_env!(env)
          end
        end

        # Extracts the proper host and guest IPs for NFS mounts and stores them
        # in the environment for the SyncedFolder action to use them in
        # mounting.
        #
        # The ! indicates that this method modifies its argument.
        def add_ips_to_env!(env)
          adapter, host_ip, is_ipv6 = find_host_only_adapter
          machine_ip                = read_static_machine_ips

          if !machine_ip
            # No static IP, attempt to use the dynamic IP.
            machine_ip = read_dynamic_machine_ip(adapter)
          else
            # We have static IPs, also attempt to read any dynamic IPs.
            # If there is no dynamic IP on the adapter, it doesn't matter. We
            # already have a static IP.
            begin
              dynamic_ip = read_dynamic_machine_ip(adapter)
            rescue Vagrant::Errors::NFSNoGuestIP
              dynamic_ip = nil
            end

            # If we found a dynamic IP and we didn't include it in the
            # machine_ip array yet, do so.
            if dynamic_ip && !machine_ip.include?(dynamic_ip)
              machine_ip.push(dynamic_ip)
            end
          end

          if host_ip && !machine_ip.empty?
            interface = @machine.provider.driver.read_host_only_interfaces.detect do |iface|
              if is_ipv6
                iface[:ipv6] == host_ip
              else
                iface[:ip] == host_ip
              end
            end
            if is_ipv6
              host_ipaddr = IPAddr.new("#{host_ip}/#{interface.fetch(:ipv6_prefix, "64")}")
            else
              host_ipaddr = IPAddr.new("#{host_ip}/#{interface.fetch(:netmask, "0.0.0.0")}")
            end

            case machine_ip
            when String
              machine_ip = nil if !host_ipaddr.include?(machine_ip)
            when Array
              machine_ip.delete_if do |m_ip|
                !host_ipaddr.include?(m_ip)
              end
              machine_ip = nil if machine_ip.empty?
            end
          end

          raise Vagrant::Errors::NFSNoHostonlyNetwork if !host_ip || !machine_ip

          env[:nfs_host_ip]    = host_ip
          env[:nfs_machine_ip] = machine_ip
        end

        # Finds first host only network adapter and returns its adapter number
        # and IP address
        #
        # @return [Integer, String] adapter number, ip address of found host-only adapter
        def find_host_only_adapter
          @machine.provider.driver.read_network_interfaces.each do |adapter, opts|
            if opts[:type] == :hostonly
              @machine.provider.driver.read_host_only_interfaces.each do |interface|
                if interface[:name] == opts[:hostonly]
                  if interface[:ipv6]
                    return adapter, interface[:ipv6], true
                  else
                    return adapter, interface[:ip], false
                  end
                end
              end
            end
          end

          nil
        end

        # Returns the IP address(es) of the guest by looking for static IPs
        # given to host only adapters in the Vagrantfile
        #
        # @return [Array]<String> Configured static IPs
        def read_static_machine_ips
          ips = []
          @machine.config.vm.networks.each do |type, options|
            options = scoped_hash_override(options, :virtualbox)

            if type == :private_network && options[:type] != :dhcp && options[:ip].is_a?(String)
              ips << options[:ip]
            end
          end

          if ips.empty?
            return nil
          end

          ips
        end

        # Returns the IP address of the guest by looking at vbox guest property
        # for the appropriate guest adapter.
        #
        # For DHCP interfaces, the guest property will not be present until the
        # guest completes
        #
        # @param [Integer] adapter number to read IP for
        # @return [String] ip address of adapter
        def read_dynamic_machine_ip(adapter)
          return nil unless adapter

          # vbox guest properties are 0-indexed, while showvminfo network
          # interfaces are 1-indexed. go figure.
          guestproperty_adapter = adapter - 1

          # we need to wait for the guest's IP to show up as a guest property.
          # retry thresholds are relatively high since we might need to wait
          # for DHCP, but even static IPs can take a second or two to appear.
          retryable(retry_options.merge(on: Vagrant::Errors::VirtualBoxGuestPropertyNotFound)) do
            @machine.provider.driver.read_guest_ip(guestproperty_adapter)
          end
        rescue Vagrant::Errors::VirtualBoxGuestPropertyNotFound
          # this error is more specific with a better error message directing
          # the user towards the fact that it's probably a reportable bug
          raise Vagrant::Errors::NFSNoGuestIP
        end

        # Separating these out so we can stub out the sleep in tests
        def retry_options
          {tries: 15, sleep: 1}
        end
      end
    end
  end
end
