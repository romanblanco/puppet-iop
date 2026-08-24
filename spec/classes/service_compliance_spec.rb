require 'spec_helper'

describe 'iop::service_compliance' do
  on_supported_os.each do |os, facts|
    context "on #{os}" do
      let(:facts) { facts }

      context 'with default parameters' do
        it { should compile.with_all_deps }

        it { should contain_podman__quadlet('iop-service-compl-ssg') }
        it { should contain_podman__quadlet('iop-service-compl-dbmigrate') }
        it { should contain_podman__quadlet('iop-service-compl-import-ssg') }
        it { should contain_podman__quadlet('iop-service-compl-service') }
        it { should contain_podman__quadlet('iop-service-compl-inventory-consumer') }
        it { should contain_podman__quadlet('iop-service-compl-goodjob') }
      end

      context 'with ensure => absent' do
        let(:params) { { ensure: 'absent' } }

        it { should compile.with_all_deps }
        it { should contain_podman__quadlet('iop-service-compl-service').with_ensure('absent') }
        it { should contain_podman__quadlet('iop-service-compl-inventory-consumer').with_ensure('absent') }
        it { should contain_podman__quadlet('iop-service-compl-goodjob').with_ensure('absent') }
      end

      context 'with custom database parameters' do
        let(:params) do
          {
            database_user: 'test_compliance_user',
            database_name: 'test_compliance_db',
            database_password: 'test_compliance_password',
          }
        end

        it { should compile.with_all_deps }
        it { should contain_podman__quadlet('iop-service-compl-service') }
        it { should contain_podman__quadlet('iop-service-compl-inventory-consumer') }
      end

      context 'secret subscription behavior' do
        let(:compliance_services) do
          [
            'iop-service-compl-dbmigrate',
            'iop-service-compl-import-ssg',
            'iop-service-compl-service',
            'iop-service-compl-inventory-consumer',
            'iop-service-compl-goodjob',
          ]
        end

        it 'should create all required database secrets' do
          should contain_podman__secret('iop-service-compliance-database-username')
          should contain_podman__secret('iop-service-compliance-database-password')
          should contain_podman__secret('iop-service-compliance-database-name')
          should contain_podman__secret('iop-service-compliance-database-host')
          should contain_podman__secret('iop-service-compliance-database-port')
        end

        it 'should ensure all compliance services subscribe to database secrets' do
          compliance_services.each do |service|
            should contain_podman__quadlet(service)
              .that_subscribes_to('Podman::Secret[iop-service-compliance-database-password]')
          end
        end
      end
    end
  end
end
