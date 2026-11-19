#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::QemuServer;
use PVE::QemuServer::Console3270;
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
            'STDIO,raw,echo=0,opost=1,onlcr=1,escape=0xf',
        ],
    },
];

for my $test ($terminal_tests->@*) {
    is_deeply(
        PVE::QemuServer::Helpers::get_terminal_command(100, $test->{args}->@*),
        $test->{expected},
        $test->{name},
    );
}

my $ifaces = PVE::QemuServer::Helpers::terminal_ifaces();
is(scalar($ifaces->@*), 23, 'terminal interfaces: 4 serial ports, 3 SCLP consoles, 16 terminals');
ok((grep { $_ eq 'terminal15' } $ifaces->@*), 'last 3270 terminal is a terminal interface');

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

# the persistent sessions of the 3270 consoles

is_deeply(
    PVE::QemuServer::Console3270::get_consoles({ arch => 's390x', ostype => 'l26' }),
    {},
    '3270 consoles: none for Linux without terminals',
);
is_deeply(
    PVE::QemuServer::Console3270::get_consoles({ arch => 's390x', ostype => 'other' }),
    { 3270 => 2 },
    '3270 consoles: the integrated 3270 console of other OS types, model 2',
);
is_deeply(
    PVE::QemuServer::Console3270::get_consoles({
        arch => 's390x',
        terminal0 => '0.0.0700',
        terminal1 => 'devno=0.0.0701,model=4',
        terminal15 => '070f,model=5',
    }),
    { 3270 => 2, terminal0 => 2, terminal1 => 4, terminal15 => 5 },
    '3270 consoles: the terminals with their models',
);
is_deeply(
    PVE::QemuServer::Console3270::get_consoles({
        arch => 's390x',
        ostype => 'l26',
        terminal3 => '0.0.0300',
    }),
    { terminal3 => 2 },
    '3270 consoles: terminals of a Linux VM',
);
is_deeply(
    PVE::QemuServer::Console3270::get_consoles({ arch => 'x86_64', ostype => 'other' }),
    {},
    '3270 consoles: none on x86_64',
);

ok(PVE::QemuServer::Console3270::is_3270_iface($_), "$_ is a 3270 console")
    for qw(3270 terminal0 terminal15);
ok(!PVE::QemuServer::Console3270::is_3270_iface($_), "$_ is no 3270 console")
    for qw(sclp sclplm serial0);

is_deeply(
    PVE::QemuServer::Console3270::session_command(100, 'terminal1', 4),
    [
        '/bin/sh',
        '-c',
        'while :; do /usr/bin/c3270 "$@"; sleep 1; done',
        'c3270',
        '-secure',
        '-model',
        '3279-4',
        '-xrm',
        'c3270.suppressActions: Quit Exit Disconnect Close Open Reconnect Execute Script'
            . ' Source Macro Prompt Set Printer PrintText Transfer Trace ScreenTrace',
        '-xrm',
        'c3270.menuBar: true',
        '-xrm',
        'c3270.mouse: true',
        'U:/var/run/qemu-server/100.terminal1',
    ],
    'session command: c3270 with the model, menu bar and mouse, restricted, restarted',
);
is_deeply(
    [map { PVE::QemuServer::Console3270::window_size($_) } 2 .. 5],
    [[27, 80], [35, 80], [46, 80], [30, 132]],
    'window sizes: 3270 screen, c3270 menu bar and status line',
);
is_deeply(
    PVE::QemuServer::Console3270::attach_command(100, '3270'),
    [
        '/usr/bin/tmux',
        '-u',
        '-S',
        '/var/run/qemu-server/100.3270.tmux',
        'attach-session',
        '-t',
        '=3270',
    ],
    'attach command: tmux session of the console',
);
is(
    PVE::QemuServer::Console3270::unit_name(100),
    'pve-qemu-3270@100.service',
    'systemd unit of the sessions',
);

done_testing();
