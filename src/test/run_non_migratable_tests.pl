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
        name => 'qeth adapters cannot be migrated with state',
        conf => {
            net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0',
            net1 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
            net2 => 'bridge=vmbr0,model=qeth,devno=0.0.0404',
        },
        state => 1,
        expected => ['net1 (qeth)', 'net2 (qeth)'],
    },
    {
        name => 'qeth adapters do not block offline migration',
        conf => { net1 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400' },
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
        { net0 => 'qeth=BC:24:11:00:00:01,devno=0.0.0400' },
        1,
        0,
    );
};
is(
    $@,
    "Cannot live-migrate, snapshot (with RAM), or hibernate a VM with: net0 (qeth)\n",
    'qeth refuses live migration, RAM snapshots and hibernation up front',
);

done_testing();
