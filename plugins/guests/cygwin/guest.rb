module VagrantPlugins
  module GuestCygwin
    class Guest < Vagrant.plugin("2", :guest)
      # Name used for guest detection
      GUEST_DETECTION_NAME = "cygwin".freeze

      def detect?(machine)
        machine.communicate.test("uname | grep -i cygwin")
      end
    end
  end
end
