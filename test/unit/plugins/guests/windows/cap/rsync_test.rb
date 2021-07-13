require_relative "../../../../base"

require Vagrant.source_root.join("plugins/guests/windows/cap/rsync")

describe "VagrantPlugins::GuestWindows::Cap::RSync" do
  let(:described_class) do
    VagrantPlugins::GuestWindows::Plugin.components.guest_capabilities[:windows].get(:rsync_pre)
  end
  let(:machine) { double("machine") }
  let(:communicator) { VagrantTests::DummyCommunicator::Communicator.new(machine) }

  before do
    allow(machine).to receive(:communicate).and_return(communicator)
  end

  after do
    communicator.verify_expectations!
  end

  describe ".rsync_pre" do
    it 'makes the guestpath directory with mkdir' do
      communicator.expect_command("mkdir \"/sync_dir\" -force")
      described_class.rsync_pre(machine, guestpath: '/sync_dir')
    end
  end
end
