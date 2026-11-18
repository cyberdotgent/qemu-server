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
}

done_testing();
