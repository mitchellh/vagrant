require "tempfile"

require_relative "../../../../lib/vagrant/util/template_renderer"

module VagrantPlugins
  module GuestHaiku
    module Cap
      class ConfigureNetworks
        include Vagrant::Util

        def self.configure_networks(machine, networks)
          networks.each do |network|
            entry = TemplateRenderer.render("guests/haiku/network_#{network[:type]}",
                                            options: network)
            Tempfile.open("vagrant-haiku-configure-networks") do |f|
              f.binmode
              f.write(entry)
              f.fsync
              f.close
              machine.communicate.upload(f.path, "/tmp/vagrant-network-entry")
            end
            machine.communicate("mv /tmp/vagrant-network-entry /boot/system/settings/network/interfaces")
            # interfaces file monitored for updates, applied by network server
          end
        end
      end
    end
  end
end
