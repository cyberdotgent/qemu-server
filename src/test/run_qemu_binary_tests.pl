#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::QemuServer::Helpers;

my $tests = [
    {
        name => 'Proxmox QEMU build',
        output => 'QEMU emulator version 11.1.3 (pve-qemu-kvm_11.1.3-2)',
        expected => '11.1.3',
    },
    {
        name => 'Debian QEMU build',
        output => 'QEMU emulator version 10.0.13 (Debian 1:10.0.13+ds-0+deb13u1)',
        expected => '10.0.13',
    },
    {
        name => 'release without micro version',
        output => 'QEMU emulator version 11.1, Copyright (c) 2003-2026',
        expected => '11.1',
    },
    {
        name => 'old PC branding',
        output => 'QEMU PC emulator version 0.12.5 (qemu-kvm-0.12.5)',
        expected => '0.12.5',
    },
    {
        name => 'QEMU-mod build',
        output => 'QEMU-mod emulator version 11.1.90'
            . ' (v11.1.0-rc1-4113-g5c29556c9e-dirty) (based on QEMU)',
        expected => '11.1.90',
    },
    {
        name => 'unknown emulator',
        output => 'Other emulator version 1.2.3',
        expected => 'unknown',
    },
];

my $dir = tempdir(CLEANUP => 1);

for my $test ($tests->@*) {
    state $i = 0;
    my $binary = "$dir/kvm" . $i++;
    my $output = $test->{output} =~ s/'/'\\''/gr;
    file_set_contents($binary, "#!/bin/sh\necho '$output'\n", 0755);

    my $version = PVE::QemuServer::Helpers::kvm_user_version($binary);
    is($version, $test->{expected}, $test->{name});
    is(
        PVE::QemuServer::Helpers::kvm_is_qemu_mod($binary),
        $test->{name} eq 'QEMU-mod build' ? 1 : 0,
        "$test->{name}: QEMU-mod detection",
    );
}

my $machine_help = <<'EOF';
Supported machines are:
x-test-sys           Made-up unversioned machine type (secure)
none                 empty machine
s390-ccw-virtio-11.1 Virtual s390x machine (version 11.1) (secure)
s390-ccw-virtio      Virtual s390x machine (version 11.2) (alias of s390-ccw-virtio-11.2)
s390-ccw-virtio-11.2 Virtual s390x machine (version 11.2) (default) (secure)
EOF

my $binary = "$dir/kvm-machines";
file_set_contents($binary, "#!/bin/sh\ncat <<'EOF'\n${machine_help}EOF\n", 0755);
is_deeply(
    PVE::QemuServer::Helpers::kvm_machine_types($binary),
    {
        'x-test-sys' => 'Made-up unversioned machine type (secure)',
        none => 'empty machine',
        's390-ccw-virtio-11.1' => 'Virtual s390x machine (version 11.1) (secure)',
        's390-ccw-virtio' => 'Virtual s390x machine (version 11.2) (alias of s390-ccw-virtio-11.2)',
        's390-ccw-virtio-11.2' => 'Virtual s390x machine (version 11.2) (default) (secure)',
    },
    'machine types with descriptions from -machine help, including aliases and unversioned ones',
);

done_testing();
