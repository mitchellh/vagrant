require "pathname"

require "vagrant/action/builder"

module VagrantPlugins
  module HyperV
    module Action
      # Include the built-in modules so we can use them as top-level things.
      include Vagrant::Action::Builtin

      def self.action_reload
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use action_halt
            b2.use action_start
          end
        end
      end

      def self.action_destroy
        Vagrant::Action::Builder.new.tap do |b|
          b.use Call, IsState, :not_created do |env1, b1|
            if env1[:result]
              b1.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b1.use Call, DestroyConfirm do |env2, b2|
              if !env2[:result]
                b2.use MessageWillNotDestroy
                next
              end

              b2.use ConfigValidate
              b2.use ProvisionerCleanup, :before
              b2.use action_halt
              b2.use DeleteVM
              b2.use SyncedFolderCleanup
            end
          end
        end
      end

      def self.action_halt
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use Call, GracefulHalt, :off, :running do |env2, b3|
              if !env2[:result]
                if env2[:force_halt]
                  b3.use HaltInstance
                else
                  b3.use StopInstance
                end
              end
            end
          end
        end
      end

      # This action packages the virtual machine into a single box file.
      def self.action_package
        Vagrant::Action::Builder.new.tap do |b|
          b.use CheckEnabled
          b.use Call, IsState, :not_created do |env1, b2|
            if env1[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use PackageSetupFolders
            b2.use PackageSetupFiles
            b2.use action_halt
            b2.use SyncedFolderCleanup
            b2.use Package
            b2.use PackageVagrantfile
            b2.use PackageMetadataJson
            b2.use Export
          end
        end
      end

      def self.action_provision
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use Call, IsState, :running do |env1, b3|
              if !env1[:result]
                b3.use Message, I18n.t("vagrant_hyperv.message_not_running")
                next
              end

              b3.use Provision
            end
          end
        end
      end

      def self.action_resume
        Vagrant::Action::Builder.new.tap do |b|
          b.use HandleBox
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b1|
            if env[:result]
              b1.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b1.use ResumeVM
            b1.use WaitForIPAddress
            b1.use WaitForCommunicator, [:running]
          end
        end
      end

      def self.action_start
        Vagrant::Action::Builder.new.tap do |b|
          b.use Call, IsState, :running do |env1, b1|
            if env1[:result]
              b1.use action_provision
              next
            end

            b1.use Call, IsState, :paused do |env2, b2|
              if env2[:result]
                b2.use action_resume
                next
              end

              b2.use Call, IsState, :saved do |env3, b3|
                # When state is `:saved` it is a snapshot being restored
                if !env3[:result]
                  b3.use Provision
                  b3.use Configure
                  b3.use SetName
                  b3.use NetSetVLan
                  b3.use NetSetMac
                end

                b3.use CleanupDisks
                b3.use Disk
                b3.use SyncedFolderCleanup
                b3.use StartInstance
                b3.use WaitForIPAddress
                b3.use WaitForCommunicator, [:running]
                b3.use SyncedFolders
                b3.use SetHostname
              end
            end
          end
        end
      end

      def self.action_up
        Vagrant::Action::Builder.new.tap do |b|
          b.use CheckEnabled
          b.use CheckAccess
          b.use HandleBox
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env1, b1|
            if env1[:result]
              b1.use Import
            end

            b1.use action_start
          end
        end
      end

      def self.action_read_state
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use ReadState
        end
      end

      def self.action_ssh
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              raise Vagrant::Errors::VMNotCreatedError
            end

            b2.use Call, IsState, :running do |env1, b3|
              if !env1[:result]
                raise Vagrant::Errors::VMNotRunningError
              end

              b3.use SSHExec
            end
          end
        end
      end

      def self.action_ssh_run
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              raise Vagrant::Errors::VMNotCreatedError
            end

            b2.use Call, IsState, :running do |env1, b3|
              if !env1[:result]
                raise Vagrant::Errors::VMNotRunningError
              end

              b3.use SSHRun
            end
          end
        end
      end

      def self.action_suspend
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use SuspendVM
          end
        end
      end

      def self.action_snapshot_delete
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use SnapshotDelete

          end
        end
      end

      def self.action_snapshot_restore
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end

            b2.use action_halt
            b2.use SnapshotRestore

            b2.use Call, IsEnvSet, :snapshot_delete do |env2, b3|
              if env2[:result]
                b3.use action_snapshot_delete
              end
            end

            b2.use action_start

          end
        end
      end

      def self.action_snapshot_save
        Vagrant::Action::Builder.new.tap do |b|
          b.use ConfigValidate
          b.use Call, IsState, :not_created do |env, b2|
            if env[:result]
              b2.use Message, I18n.t("vagrant_hyperv.message_not_created")
              next
            end
            b2.use SnapshotSave
          end
        end
      end

      # The autoload farm
      action_root = Pathname.new(File.expand_path("../action", __FILE__))
      autoload :PackageSetupFolders, action_root.join("package_setup_folders")
      autoload :PackageSetupFiles, action_root.join("package_setup_files")
      autoload :PackageVagrantfile, action_root.join("package_vagrantfile")
      autoload :PackageMetadataJson, action_root.join("package_metadata_json")
      autoload :Export, action_root.join("export")

      autoload :CheckEnabled, action_root.join("check_enabled")
      autoload :CheckAccess, action_root.join("check_access")
      autoload :Configure, action_root.join("configure")
      autoload :DeleteVM, action_root.join("delete_vm")
      autoload :HaltInstance, action_root.join("halt_instance")
      autoload :Import, action_root.join("import")
      autoload :Package, action_root.join("package")
      autoload :IsWindows, action_root.join("is_windows")
      autoload :ReadState, action_root.join("read_state")
      autoload :ResumeVM, action_root.join("resume_vm")
      autoload :StartInstance, action_root.join('start_instance')
      autoload :StopInstance, action_root.join('stop_instance')
      autoload :SuspendVM, action_root.join("suspend_vm")
      autoload :WaitForIPAddress, action_root.join("wait_for_ip_address")
      autoload :NetSetVLan, action_root.join("net_set_vlan")
      autoload :NetSetMac, action_root.join("net_set_mac")
      autoload :MessageWillNotDestroy, action_root.join("message_will_not_destroy")
      autoload :SnapshotDelete, action_root.join("snapshot_delete")
      autoload :SnapshotRestore, action_root.join("snapshot_restore")
      autoload :SnapshotSave, action_root.join("snapshot_save")
      autoload :SetName, action_root.join("set_name")
    end
  end
end
