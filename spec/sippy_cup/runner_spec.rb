require 'sippy_cup/runner'

describe SippyCup::Runner do
  let(:settings) { Hash.new }
  let(:command) { "sudo sipp -i 127.0.0.1" }
  let(:pid) { '1234' }

  before { subject.logger.stub :info }

  subject { SippyCup::Runner.new settings }

  describe '#run' do
    context "System call fails/doesn't fail" do
      it 'should raise an error when the system call fails' do
        subject.should_receive(:prepare_command).and_return command
        subject.should_receive(:spawn).with(command, an_instance_of(Hash)).and_raise(Errno::ENOENT)
        Process.stub :wait2
        subject.stub :process_exit_status
        expect { subject.run }.to raise_error Errno::ENOENT
      end

      it 'should not raise an error when the system call is successful' do
        subject.should_receive(:prepare_command).and_return command
        subject.should_receive(:spawn).with(command, an_instance_of(Hash)).and_return pid
        Process.stub :wait2
        subject.stub :process_exit_status
        expect { subject.run }.not_to raise_error
      end
    end

    context "specifying a stats file" do
      let(:settings) { { stats_file: 'stats.csv' } }
      let(:command) { "sudo sipp -i 127.0.0.1 -trace_stats -stf stats.csv" }

      it 'should display the path to the csv file when one is specified' do
        subject.should_receive(:prepare_command).and_return command
        subject.should_receive(:spawn).with(command, an_instance_of(Hash)).and_return pid
        Process.stub :wait2
        subject.stub :process_exit_status
        subject.logger.should_receive(:info).with "Statistics logged at #{File.expand_path settings[:stats_file]}"
        subject.run
      end
    end

    context "no stats file" do
      it 'should not display a csv file path if none is specified' do
        subject.logger.should_receive(:info).ordered.with(/Preparing to run SIPp command/)
        subject.logger.should_receive(:info).ordered.with(/Test completed successfully/)
        subject.should_receive(:prepare_command).and_return command
        subject.should_receive(:spawn).with(command, an_instance_of(Hash)).and_return pid
        Process.stub :wait2
        subject.stub :process_exit_status
        subject.run
      end
    end

    context "CSV file" do
      let(:settings) { {scenario_variables: "/path/to/csv", scenario: "/path/to/scenario", source: "127.0.0.1",
                        destination: "127.0.0.1", max_concurrent: 5, calls_per_second: 5,
                        number_of_calls: 5} }

      it 'should use CSV into the test run' do
        subject.logger.should_receive(:info).ordered.with(/Preparing to run SIPp command/)
        subject.logger.should_receive(:info).ordered.with(/Test completed successfully/)
        subject.should_receive(:spawn).with(/\-inf \/path\/to\/csv/, an_instance_of(Hash))
        Process.stub :wait2
        subject.stub :process_exit_status
        subject.run
      end
    end

    describe 'SIPp exit status handling' do
      let(:error_string) { "Some error" }
      let(:exit_code) { 255 }
      let(:command) { "sh -c 'echo \"#{error_string}\" 1>&2; exit #{exit_code}'" }

      before do
        subject.should_receive(:prepare_command).and_return command
      end

      context "with normal operation" do
        let(:exit_code) { 0 }

        it "should not raise anything if SIPp returns 0" do
          quietly do
            expect { subject.run }.to_not raise_error
          end
        end
      end

      context "with at least one call failure" do
        let(:exit_code) { 1 }

        it "should return false if SIPp returns 1" do
          quietly do
            subject.logger.should_receive(:info).ordered.with(/Test completed successfully but some calls failed./)
            subject.run.should == false
          end
        end
      end

      context "with an exit from inside SIPp" do
        let(:exit_code) { 97 }

        it "should raise a ExitOnInternalCommand error if SIPp returns 97" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::ExitOnInternalCommand, error_string
          end
        end
      end

      context "with no calls processed" do
        let(:exit_code) { 99 }

        it "should raise a NoCallsProcessed error if SIPp returns 99" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::NoCallsProcessed, error_string
          end
        end
      end

      context "with a fatal error" do
        let(:exit_code) { 255 }

        it "should raise a FatalError error if SIPp returns 255" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::FatalError, error_string
          end
        end
      end

      context "with a socket binding fatal error" do
        let(:exit_code) { 254 }

        it "should raise a FatalSocketBindingError error if SIPp returns 254" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::FatalSocketBindingError, error_string
          end
        end
      end

      context "with a generic undocumented fatal error" do
        let(:exit_code) { 128 }

        it "should raise a SippGenericError error if SIPp returns 255" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::SippGenericError, error_string
          end
        end

        it "should raise a SippGenericError error with the appropriate message" do
          quietly do
            expect { subject.run }.to raise_error SippyCup::SippGenericError, error_string
          end
        end
      end
    end

    describe "SIPp stdout/stderr" do
      let(:error_string) { "Some error" }
      let(:exit_code) { 128 }
      let(:command) { "sh -c 'echo \"#{error_string}\" 1>&2; exit #{exit_code}'" }

      def capture_stderr(&block)
        original_stderr = $stderr
        $stderr = fake = StringIO.new
        begin
          yield
        ensure
          $stderr = original_stderr
        end
        fake.string
      end

      context "with :full_sipp_output enabled" do
        let(:settings) { Hash.new full_sipp_output: true }

        it "proxies stderr to the terminal" do
          subject.should_receive(:prepare_command).and_return command
          stderr = capture_stderr do
            expect { subject.run }.to raise_error
          end
          stderr.should == error_string
        end
      end
    end
  end

  describe '#stop' do
    before { subject.sipp_pid = pid }

    it "should try to kill the SIPp process if there is a PID" do
      Process.should_receive(:kill).with("KILL", pid)
      subject.stop
    end

    context "if there is no PID available" do
      let(:pid) { nil }

      it "should not try to kill the SIPp process" do
        Process.should_receive(:kill).never
        subject.stop
      end
    end

    it "should raise a Errno::ESRCH if the PID does not exist" do
      Process.should_receive(:kill).with("KILL", pid).and_raise(Errno::ESRCH)
      expect { subject.stop }.to raise_error Errno::ESRCH
    end

    it "should raise a Errno::EPERM if the user has no permission to kill the process" do
      Process.should_receive(:kill).with("KILL", pid).and_raise(Errno::EPERM)
      expect { subject.stop }.to raise_error Errno::EPERM
    end
  end
end
