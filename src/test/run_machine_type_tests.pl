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

done_testing();
