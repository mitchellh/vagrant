require "tempfile"

require_relative "../../../../lib/vagrant/util/template_renderer"

module VagrantPlugins
  module GuestRedHat
    module Cap
      class ConfigureNetworks
        include Vagrant::Util
        extend Vagrant::Util::GuestInspection::Linux

        def self.configure_networks(machine, networks)
          comm = machine.communicate

          network_scripts_dir = machine.guest.capability(:network_scripts_dir)

          commands   = {:start => [], :middle => [], :end => []}
          interfaces = machine.guest.capability(:network_interfaces)

          # Check if NetworkManager is installed on the system
          nmcli_installed = nmcli?(comm)
          net_configs = machine.config.vm.networks.map do |type, opts|
            opts if type.to_s.end_with?("_network")
          end.compact
          networks.each.with_index do |network, i|
            network[:device] = interfaces[network[:interface]]
            extra_opts = net_configs[i] ? net_configs[i].dup : {}

            if nmcli_installed
              # Now check if the device is actively being managed by NetworkManager
              nm_controlled = nm_controlled?(comm, network[:device])
            end

            if !extra_opts.key?(:nm_controlled)
              extra_opts[:nm_controlled] = !!nm_controlled
            end

            extra_opts[:nm_controlled] = case extra_opts[:nm_controlled]
                                      when true
                                        "yes"
                                      when false, nil
                                        "no"
                                      else
                                        extra_opts[:nm_controlled].to_s
                                      end

            if extra_opts[:nm_controlled] == "yes" && !nmcli_installed
              raise Vagrant::Errors::NetworkManagerNotInstalled, device: network[:device]
            end

            # Render static route file if present
            if network.key?(:route) && network[:route] != nil
              routeentry = TemplateRenderer.render("guests/redhat/network_route",
                routes: network[:route],
              )
              route_remote_path = "/tmp/vagrant-network-route-entry-#{network[:device]}-#{Time.now.to_i}-#{i}"
              Tempfile.open("vagrant-redhat-configure-networks-routes") do |f|
                f.binmode
                f.write(routeentry)
                f.fsync
                f.close
                machine.communicate.upload(f.path, route_remote_path)
              end
              route_final_path = "#{network_scripts_dir}/route-#{network[:device]}"
              commands[:middle] << "mv -f '#{route_remote_path}' '#{route_final_path}'"
            end

            # Render a new configuration
            entry = TemplateRenderer.render("guests/redhat/network_#{network[:type]}",
              options: extra_opts.merge(network),
            )

            # Upload the new configuration
            remote_path = "/tmp/vagrant-network-entry-#{network[:device]}-#{Time.now.to_i}-#{i}"
            Tempfile.open("vagrant-redhat-configure-networks") do |f|
              f.binmode
              f.write(entry)
              f.fsync
              f.close
              machine.communicate.upload(f.path, remote_path)
            end

            # Add the new interface and bring it back up
            final_path = "#{network_scripts_dir}/ifcfg-#{network[:device]}"

            if nm_controlled
              commands[:start] << "nmcli d disconnect iface '#{network[:device]}'"
            else
              commands[:start] << "/sbin/ifdown '#{network[:device]}'"
            end
            commands[:middle] << "mv -f '#{remote_path}' '#{final_path}'"
            if extra_opts[:nm_controlled] == "no"
              commands[:end] << "/sbin/ifup '#{network[:device]}'"
            end
          end
          if nmcli_installed
            commands[:middle] << "(test -f /etc/init.d/NetworkManager && /etc/init.d/NetworkManager restart) || " \
              "((systemctl | grep NetworkManager.service) && systemctl restart NetworkManager)"
          end
          commands = commands[:start] + commands[:middle] + commands[:end]
          comm.sudo(commands.join("\n"))
          comm.wait_for_ready(5)
        end
      end
    end
  end
end
