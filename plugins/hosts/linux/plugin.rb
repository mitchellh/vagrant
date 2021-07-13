require "vagrant"

module VagrantPlugins
  module HostLinux
    class Plugin < Vagrant.plugin("2")
      name "Linux host"
      description "Linux host support."

      host("linux") do
        require_relative "host"
        Host
      end

      host_capability("linux", "isofs_available") do
        require_relative "cap/fs_iso"
        Cap::FsISO
      end

      host_capability("linux", "create_iso") do
        require_relative "cap/fs_iso"
        Cap::FsISO
      end

      host_capability("linux", "nfs_export") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "nfs_installed") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "nfs_prune") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "rdp_client") do
        require_relative "cap/rdp"
        Cap::RDP
      end

      # Linux-specific helpers we need to determine paths that can
      # be overridden.
      host_capability("linux", "nfs_apply_command") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "nfs_check_command") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "nfs_start_command") do
        require_relative "cap/nfs"
        Cap::NFS
      end

      host_capability("linux", "set_ssh_key_permissions") do
        require_relative "cap/ssh"
        Cap::SSH
      end

      host_capability("linux", "smb_installed") do
        require_relative "cap/smb"
        Cap::SMB
      end

      host_capability("linux", "smb_prepare") do
        require_relative "cap/smb"
        Cap::SMB
      end

      host_capability("linux", "smb_cleanup") do
        require_relative "cap/smb"
        Cap::SMB
      end

      host_capability("linux", "configured_ip_addresses") do
        require_relative "cap/configured_ip_addresses"
        Cap::ConfiguredIPAddresses
      end
    end
  end
end
