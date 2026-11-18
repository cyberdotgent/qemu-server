#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::QemuServer::Helpers;

my $consoles_tests = [
    [undef, ['sclplm', '3270']],
    ['other', ['sclplm', '3270']],
    ['l24', ['sclp']],
    ['l26', ['sclp']],
    ['solaris', ['sclplm', '3270']],
    ['win11', ['sclplm', '3270']],
];

for my $test ($consoles_tests->@*) {
    my ($ostype, $expected) = $test->@*;
    my $conf = { arch => 's390x', defined($ostype) ? (ostype => $ostype) : () };
    is_deeply(
        PVE::QemuServer::Helpers::get_s390x_consoles($conf),
        $expected,
        "s390x consoles for OS type " . ($ostype // "(unset)"),
    );
}

my $terminal_tests = [
    {
        name => 'serial port with escape key',
        args => ['serial0', 0x0f],
        expected => [
            'socat',
            'UNIX-CONNECT:/var/run/qemu-server/100.serial0',
            'STDIO,raw,echo=0,escape=0xf',
        ],
    },
    {
        name => 'VT220 SCLP console without escape key',
        args => ['sclp', 0],
        expected => ['socat', 'UNIX-CONNECT:/var/run/qemu-server/100.sclp', 'STDIO,raw,echo=0'],
    },
    {
        name => 'line-mode SCLP console, edited by QEMU',
        args => ['sclplm', 0x0f],
        expected => [
            'socat',
            'UNIX-CONNECT:/var/run/qemu-server/100.sclplm',
            'STDIO,raw,echo=0,escape=0xf',
        ],
    },
    {
        name => 'integrated 3270 console uses c3270',
        args => ['3270', 0x0f],
        expected => ['c3270', 'U:/var/run/qemu-server/100.3270'],
    },
];

for my $test ($terminal_tests->@*) {
    is_deeply(
        PVE::QemuServer::Helpers::get_terminal_command(100, $test->{args}->@*),
        $test->{expected},
        $test->{name},
    );
}

my $device_help = <<'EOF';
Controller/Bridge/Hub devices:
name "virtio-serial-ccw", bus virtual-css-bus
name "virtio-serial-device", bus virtio-bus

Input devices:
name "sclp3270console", bus s390-sclp-events-bus
name "sclpconsole", bus s390-sclp-events-bus
name "sclplmconsole", bus s390-sclp-events-bus
EOF

my $dir = tempdir(CLEANUP => 1);
my $binary = "$dir/kvm-devices";
file_set_contents($binary, "#!/bin/sh\ncat <<'EOF'\n${device_help}EOF\n", 0755);
is_deeply(
    PVE::QemuServer::Helpers::kvm_device_types($binary),
    {
        'virtio-serial-ccw' => 1,
        'virtio-serial-device' => 1,
        sclp3270console => 1,
        sclpconsole => 1,
        sclplmconsole => 1,
    },
    'device types from -device help',
);

done_testing();
