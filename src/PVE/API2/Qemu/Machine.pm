package PVE::API2::Qemu::Machine;

use strict;
use warnings;

use JSON;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::Tools qw(extract_param file_get_contents);

use PVE::QemuServer::CPUConfig;
use PVE::QemuServer::Machine;
use PVE::QemuServer::Helpers qw(get_host_arch);

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'types',
    path => '',
    method => 'GET',
    proxyto => 'node',
    description => "Get available QEMU/KVM machine types.",
    permissions => {
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            arch => get_standard_option('pve-qm-cpu-arch', { optional => 1 }),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            additionalProperties => 1,
            properties => {
                id => {
                    type => 'string',
                    description => "Full name of machine type and version.",
                },
                type => {
                    type => 'string',
                    description => "The machine type, like 'q35', 'i440fx', 'virt' or"
                        . " 's390-ccw-virtio'. For an unversioned machine type of the QEMU build,"
                        . " its name; for a versioned one with an alias (s390x 'czam-v1'), the"
                        . " alias ('czam').",
                },
                class => {
                    type => 'string',
                    enum => ['virtio', 'mainframe'],
                    optional => 1,
                    description => "s390x only: 'virtio' for the paravirtual machine (firmware"
                        . " boot, CD-ROM drives), 'mainframe' for the machines of QEMU builds with"
                        . " mainframe support (channel-program IPL, no CD-ROM drives).",
                },
                description => {
                    type => 'string',
                    optional => 1,
                    description => "The description of an unversioned machine type.",
                },
                'new-vm-default' => {
                    type => 'boolean',
                    optional => 1,
                    description => "Set for the machine type a new VM without a configured"
                        . " machine type gets.",
                },
                version => {
                    type => 'string',
                    description => "The machine version. For a versioned machine type of the"
                        . " QEMU build with an alias, its version ('v1' of 'czam-v1'), for other"
                        . " machine types of the QEMU build the QEMU version.",
                },
                changes => {
                    type => 'string',
                    optional => 1,
                    description => 'Notable changes of a version, currently only set for +pveX'
                        . ' versions, and only where they change something for the architecture.',
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $arch = extract_param($param, 'arch') // get_host_arch();

        my $supported_machine_list = eval {
            my $raw = file_get_contents("/usr/share/kvm/machine-versions-$arch.json");
            my $machines = from_json($raw, { utf8 => 1 });

            my $pve_machines = [];
            for my $machine ($machines->@*) {
                my $pve_machine =
                    PVE::QemuServer::Machine::get_machine_pve_revisions($machine->{version})
                    or next;

                for my $pve_revision (sort keys $pve_machine->{revisions}->%*) {
                    my $entry = {
                        id => $machine->{id} . $pve_revision,
                        type => $machine->{type},
                        version => $machine->{version} . $pve_revision,
                    };

                    my ($base_version) = $machine->{version} =~ m/^(\d+\.\d+)/;
                    if (
                        defined(
                            my $changes = PVE::QemuServer::Machine::machine_revision_changes(
                                $base_version, $pve_revision, $arch,
                            )
                        )
                    ) {
                        $entry->{changes} = $changes;
                    }

                    push $pve_machines->@*, $entry;
                }
            }

            return [
                sort {
                    PVE::QemuServer::Machine::machine_version_cmp($b->{id}, $a->{id})
                } ($machines->@*, $pve_machines->@*)
            ]; # merge & sort
        };
        die "could not load supported machine versions - $@\n" if $@;

        if ($arch eq 's390x') {
            $_->{class} = 'virtio' for $supported_machine_list->@*;

            # the unversioned machine types the QEMU build offers, used as-is; the versioned ones
            # with an alias are versions of the alias (czam-v1 of czam)
            my $kvm_binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
            unshift $supported_machine_list->@*,
                PVE::QemuServer::Machine::s390x_mainframe_machine_entries($kvm_binary)->@*;

            my $default = PVE::QemuServer::Machine::default_new_machine_for_arch($arch, $kvm_binary);
            for my $entry ($supported_machine_list->@*) {
                $entry->{'new-vm-default'} = 1 if $entry->{id} eq $default;
            }
        }

        return $supported_machine_list;
    },
});

1;
