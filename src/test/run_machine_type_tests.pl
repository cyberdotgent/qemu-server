#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::QemuServer::Machine;

my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(kvm_user_version => sub { return '11.1.90' });

my $versioned = [
    qw(
        pc
        pc.pxe
        pc+pve1
        q35
        virt
        s390-ccw-virtio
        pc-i440fx-10.1.pxe
        pc-q35-11.0+pve2
        pc-5.1
        virt-9.2
        s390-ccw-virtio-10.1+pve0
    ),
];

# made-up names, the machine types of a QEMU build are only known at runtime
my $unversioned = [
    qw(
        x-test-sys
        x-test-lpar
        virtual-lpar
        pcx
        none
    ),
];

for my $machine ($versioned->@*) {
    ok(!PVE::QemuServer::Machine::is_unversioned_machine_type($machine), "$machine is versioned");
}

for my $machine ($unversioned->@*) {
    ok(PVE::QemuServer::Machine::is_unversioned_machine_type($machine), "$machine is unversioned");

    my $conf = { arch => 's390x', machine => $machine };
    is(PVE::QemuServer::Machine::get_vm_machine($conf), $machine, "$machine is used as-is");
    is(
        PVE::QemuServer::Machine::get_vm_machine($conf, $machine),
        $machine,
        "forced $machine is used as-is",
    );
    is(
        PVE::QemuServer::Machine::extract_version($machine),
        '11.1+pve0',
        "$machine follows the installed QEMU",
    );
    ok(
        PVE::QemuServer::Machine::is_machine_version_at_least($machine, 10, 0),
        "$machine is at least 10.0",
    );
    ok(
        !defined(PVE::QemuServer::Machine::get_power_state_flags({ type => $machine }, 's390x')),
        "$machine has no S3/S4 flags",
    );
}

# the schema accepts a +pveX revision only for the known machine families
for my $machine (qw(x-test-sys x-test-lpar s390-ccw-virtio-11.1+pve0 virt+pve1)) {
    my $res = eval { PVE::QemuServer::Machine::parse_machine($machine) };
    is($res->{type}, $machine, "schema accepts $machine");
}

for my $machine (qw(x-test-sys+pve1 x-test-lpar.pxe X-TEST-SYS -lpar lpar-)) {
    eval { PVE::QemuServer::Machine::parse_machine($machine) };
    ok($@, "schema rejects $machine");
}

# s390x machine classes: the paravirtual s390-ccw-virtio machine, and the machine types of QEMU builds
# with mainframe support
for my $machine (qw(s390-ccw-virtio s390-ccw-virtio-11.1 s390-ccw-virtio-10.1+pve0)) {
    is(PVE::QemuServer::Machine::s390x_machine_class($machine), 'virtio', "$machine is virtio");
}
for my $machine (qw(x-test-lpar virtual-lpar)) {
    is(PVE::QemuServer::Machine::s390x_machine_class($machine), 'mainframe', "$machine is mainframe");
}

my $machine_types = {};
$helpers->mock(kvm_machine_types => sub { return $machine_types });

$machine_types = {
    'none' => 'empty machine',
    's390-ccw-virtio' => 'Virtual s390x machine (version 11.1) (alias of s390-ccw-virtio-11.1)',
    's390-ccw-virtio-11.1' => 'Virtual s390x machine (version 11.1) (default)',
    'x-remote' => 'Experimental remote machine',
    'virtual-lpar-b' => 'LPAR B',
    'virtual-lpar-a' => 'LPAR A',
};
is_deeply(
    PVE::QemuServer::Machine::s390x_mainframe_machine_types('/usr/bin/kvm'),
    { 'virtual-lpar-a' => 'LPAR A', 'virtual-lpar-b' => 'LPAR B' },
    'mainframe machine types of the binary, without none and x-',
);
is(
    PVE::QemuServer::Machine::default_new_machine_for_arch('s390x', '/usr/bin/kvm'),
    'virtual-lpar-a',
    'new s390x VMs get the first mainframe machine type',
);
# a versioned mainframe machine type with an alias to its newest version, and a deprecated alias
# (an old name) that existing configurations keep using
$machine_types = {
    'none' => 'empty machine',
    's390-ccw-virtio' => 'Virtual s390x machine (version 11.1) (alias of s390-ccw-virtio-11.1)',
    's390-ccw-virtio-11.1' => 'Virtual s390x machine (version 11.1) (default)',
    'czam-v1' => 'CZAM hardware mode (version 1)',
    'czam' => 'CZAM hardware mode (version 1) (alias of czam-v1)',
    'aaa-old' => 'Old name (alias of czam-v1) (deprecated)',
};
is_deeply(
    [sort keys PVE::QemuServer::Machine::s390x_mainframe_machine_types('/usr/bin/kvm')->%*],
    [qw(czam czam-v1)],
    'mainframe machine types for new configurations, without deprecated ones',
);
is(
    PVE::QemuServer::Machine::default_new_machine_for_arch('s390x', '/usr/bin/kvm'),
    'czam',
    'new s390x VMs get the alias of the newest version of a versioned mainframe machine type',
);
# the machine type API: czam-v1 is a version of czam, not a type of its own
is_deeply(
    PVE::QemuServer::Machine::s390x_mainframe_machine_entries('/usr/bin/kvm'),
    [
        {
            id => 'czam',
            type => 'czam',
            version => '11.1',
            class => 'mainframe',
            description => 'CZAM hardware mode (version 1) (alias of czam-v1)',
        },
        {
            id => 'czam-v1',
            type => 'czam',
            version => 'v1',
            class => 'mainframe',
            description => 'CZAM hardware mode (version 1)',
        },
    ],
    'machine type API entries: the versions of a mainframe machine type have the alias as type',
);
is(
    PVE::QemuServer::Machine::s390x_machine_class('aaa-old'),
    'mainframe',
    'a deprecated mainframe machine type of existing configurations is still mainframe class',
);
is(
    PVE::QemuServer::Machine::get_vm_machine({ machine => 'aaa-old', arch => 's390x' }),
    'aaa-old',
    'a deprecated alias is passed to QEMU as configured',
);
is(
    PVE::QemuServer::Machine::get_vm_machine({ machine => 'czam', arch => 's390x' }, 'czam-v1'),
    'czam-v1',
    'the running version of a mainframe machine type is kept (migration, resume)',
);
delete $machine_types->@{qw(czam czam-v1 aaa-old)};
is(
    PVE::QemuServer::Machine::default_new_machine_for_arch('s390x', '/usr/bin/kvm'),
    's390-ccw-virtio',
    'new s390x VMs get the virtio machine without a mainframe machine type',
);
is(PVE::QemuServer::Machine::default_new_machine_for_arch('x86_64'), 'pc', 'x86_64 default');

# change notes of +pveX revisions only where they change something for the architecture
is(
    PVE::QemuServer::Machine::machine_revision_changes('11.0', '+pve2', 'x86_64'),
    'Enable hv_emcs for Windows 11/2022/2025 to mitigate issues with VBS.',
    'hv_emcs note on x86_64',
);
is(PVE::QemuServer::Machine::machine_revision_changes('11.0', '+pve2', 's390x'), undef,
    'no hv_emcs note on s390x');
is(PVE::QemuServer::Machine::machine_revision_changes('9.2', '+pve1', 'aarch64'), undef,
    'no S3/S4 note on aarch64');
like(PVE::QemuServer::Machine::machine_revision_changes('11.0', '+pve1', 's390x'), qr/host_tunnel/,
    'VirtIO NIC note on s390x');
is(PVE::QemuServer::Machine::machine_revision_changes('11.0', '+pve9', 's390x'), undef,
    'unknown revision');
for my $key (keys $PVE::QemuServer::Machine::PVE_MACHINE_REVISION_ARCHES->%*) {
    my ($version, $revision) = $key =~ m/^(\d+\.\d+)(\+pve\d+)$/;
    ok(
        defined($version)
            && defined($PVE::QemuServer::Machine::PVE_MACHINE_VERSION->{$version}->{revisions}->{$revision}),
        "architectures of $key: a known revision",
    );
}

done_testing();
