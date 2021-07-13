require_relative "../../../../base"

describe "VagrantPlugins::GuestCygwin::Cap::RemovePublicKey" do
  let(:caps) do
    VagrantPlugins::GuestCygwin::Plugin
      .components
      .guest_capabilities[:cygwin]
  end

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }

  before do
    allow(machine).to receive(:communicate).and_return(comm)
  end

  after do
    comm.verify_expectations!
  end

  describe ".remove_public_key" do
    let(:cap) { caps.get(:remove_public_key) }

    it "removes the public key" do
      cap.remove_public_key(machine, "ssh-rsa ...")
      expect(comm.received_commands[0]).to match(/grep -v -x -f '\/tmp\/vagrant-(.+)' ~\/\.ssh\/authorized_keys > ~\/.ssh\/authorized_keys\.tmp/)
      expect(comm.received_commands[0]).to match(/mv ~\/.ssh\/authorized_keys\.tmp ~\/.ssh\/authorized_keys/)
      expect(comm.received_commands[0]).to match(/chmod 0600 ~\/.ssh\/authorized_keys/)
      expect(comm.received_commands[0]).to match(/rm -f '\/tmp\/vagrant-(.+)'/)
    end
  end
end
