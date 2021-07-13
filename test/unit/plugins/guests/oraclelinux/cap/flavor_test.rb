# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

require_relative "../../../../base"

describe "VagrantPlugins::GuestOracleLinux::Cap::Flavor" do
  let(:caps) do
    VagrantPlugins::GuestOracleLinux::Plugin
      .components
      .guest_capabilities[:oraclelinux]
  end

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }

  before do
    allow(machine).to receive(:communicate).and_return(comm)
  end

  after do
    comm.verify_expectations!
  end

  describe ".flavor" do
    let(:cap) { caps.get(:flavor) }

    {
      "Oracle Linux Server release 7.8" => :oraclelinux_7,
      "Oracle Linux Server release 8.2" => :oraclelinux_8,
      "Oracle Linux Server release 6.10" => :oraclelinux,
      "Unexpected release" => :oraclelinux,
    }.each do |str, expected|
      it "returns #{expected} for #{str}" do
        comm.stub_command("cat /etc/oracle-release", stdout: str)
        expect(cap.flavor(machine)).to be(expected)
      end
    end
  end
end
