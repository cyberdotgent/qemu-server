#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;

use PVE::QemuMigrate::Helpers;

my $tests = [
    {
        name => 'no blockers',
        conf => { net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0' },
        state => 1,
        expected => [],
    },
    {
        name => 'mainframe devices can be migrated with state',
        conf => {
            net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0',
            net1 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
            net2 => 'bridge=vmbr0,model=qeth,devno=0.0.0404',
            ckd0 => 'local:100/vm-100-disk-0.raw,size=1G',
            tape0 => 'local:iso/install.aws',
            terminal0 => 'devno=0.0.0700',
        },
        state => 1,
        expected => [],
    },
    {
        name => 'confidential computing blocks state',
        conf => { 'amd-sev' => 'type=std' },
        state => 1,
        expected => ['amd-sev'],
    },
    {
        name => 'confidential computing does not block offline migration',
        conf => { 'amd-sev' => 'type=std' },
        state => 0,
        expected => [],
    },
];

for my $test ($tests->@*) {
    my @blockers = PVE::QemuMigrate::Helpers::check_non_migratable_resources(
        $test->{conf}, $test->{state}, 1,
    );
    is_deeply(\@blockers, $test->{expected}, $test->{name});
}

eval {
    PVE::QemuMigrate::Helpers::check_non_migratable_resources(
        { 'amd-sev' => 'type=std', ckd0 => 'local:100/vm-100-disk-0.raw,size=1G' },
        1,
        0,
    );
};
is(
    $@,
    "Cannot live-migrate, snapshot (with RAM), or hibernate a VM with: amd-sev\n",
    'blockers refuse live migration, RAM snapshots and hibernation up front',
);

done_testing();
