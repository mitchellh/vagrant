module VagrantPlugins
  module GuestHaiku
    module Cap
      class NetworkInterfaces
        @@logger = Log4r::Logger.new("vagrant::guest::haiku::network_interfaces")

        # Get network interfaces as a list. The result will be something like:
        #
        #   /dev/net/virtio/0,/dev/net/virtio/1,etc
        #
        # @return [Array<String>]
        def self.network_interfaces(machine, path = "/bin/ifconfig")
          ifaces = Array.new 
          machine.communicate("#{path} -a | grep -o ^[0-9a-z\/]* | grep -v loop") do |type, data|
            ifaces.push(data) if type == :stdout
          end

          @@logger.debug("Network device list: #{ifaces.inspect}")
          ifaces
        end
      end
    end
  end
end
