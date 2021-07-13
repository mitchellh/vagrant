module VagrantPlugins
  module GuestWindows
    module Cap
      module Halt
        def self.halt(machine)
          # Fix vagrant-windows GH-129, if there's an existing scheduled
          # reboot cancel it so shutdown succeeds
          machine.communicate.execute("shutdown -a", error_check: false)

          # Force shutdown the machine now
          begin
            machine.communicate.execute("shutdown /s /t 1 /c \"Vagrant Halt\" /f /d p:4:1")
          rescue Vagrant::Errors::VagrantError
            machine.communicate.execute("shutdown /s /t 1 /c \"Vagrant Halt\" /f")
          end
        end
      end
    end
  end
end
