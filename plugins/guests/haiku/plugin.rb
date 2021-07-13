require "vagrant"

module VagrantPlugins
  module GuestHaiku
    class Plugin < Vagrant.plugin("2")
      name "Haiku guest"
      description "Haiku guest support."

      guest(:haiku) do
        require_relative "guest"
        Guest
      end

      guest_capability(:haiku, :halt) do
        require_relative "cap/halt"
        Cap::Halt
      end

      guest_capability(:haiku, :change_host_name) do
        require_relative "cap/change_host_name"
        Cap::ChangeHostName
      end

      guest_capability(:haiku, :network_interfaces) do
        require_relative "cap/network_interfaces"
        Cap::ConfigureNetworks
      end

      guest_capability(:haiku, :configure_networks) do
        require_relative "cap/configure_networks"
        Cap::ConfigureNetworks
      end

      guest_capability(:haiku, :insert_public_key) do
        require_relative "cap/insert_public_key"
        Cap::InsertPublicKey
      end

      guest_capability(:haiku, :remove_public_key) do
        require_relative "cap/remove_public_key"
        Cap::RemovePublicKey
      end

      guest_capability(:haiku, :rsync_install) do
        require_relative "cap/rsync"
        Cap::RSync
      end

      guest_capability(:haiku, :rsync_installed) do
        require_relative "cap/rsync"
        Cap::RSync
      end

      guest_capability(:haiku, :rsync_command) do
        require_relative "cap/rsync"
        Cap::RSync
      end
    end
  end
end
