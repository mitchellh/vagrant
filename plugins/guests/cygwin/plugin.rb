require "vagrant"

module VagrantPlugins
  module GuestCygwin
    class Plugin < Vagrant.plugin("2")
      name "Cygwin guest."
      description "Cygwin guest support."

      guest(:cygwin) do
        require_relative "guest"
        Guest
      end

      guest_capability(:cygwin, :create_tmp_path) do
        require_relative "cap/file_system"
        Cap::FileSystem
      end

      guest_capability(:cygwin, :decompress_tgz) do
        require_relative "cap/file_system"
        Cap::FileSystem
      end

      guest_capability(:cygwin, :decompress_zip) do
        require_relative "cap/file_system"
        Cap::FileSystem
      end

      guest_capability(:cygwin, :insert_public_key) do
        require_relative "cap/public_key"
        Cap::PublicKey
      end

      guest_capability(:cygwin, :remove_public_key) do
        require_relative "cap/public_key"
        Cap::PublicKey
      end

      guest_capability(:cygwin, :shell_expand_guest_path) do
        require_relative "cap/shell_expand_guest_path"
        Cap::ShellExpandGuestPath
      end

      guest_capability(:cygwin, :rsync_installed) do
        require_relative "cap/rsync"
        Cap::RSync
      end

      guest_capability(:cygwin, :rsync_command) do
        require_relative "cap/rsync"
        Cap::RSync
      end

      guest_capability(:cygwin, :rsync_post) do
        require_relative "cap/rsync"
        Cap::RSync
      end

      guest_capability(:cygwin, :rsync_pre) do
        require_relative "cap/rsync"
        Cap::RSync
      end

    end
  end
end
