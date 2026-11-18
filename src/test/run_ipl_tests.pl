#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;

use PVE::File qw(file_set_contents);
use PVE::QemuServer::Helpers;
use PVE::QemuServer::IPL;

# what QEMU-mod reports, ipl-method of the IPL-capable types
my $qemu_mod_ipl_methods = {
    '3590-ccw' => 'ccw',
    'eckd-ccw' => 'ccw',
    'fba-ccw' => 'ccw',
    'vfio-ccw' => 'ccw',
    'scsi-block' => 'firmware',
    'scsi-cd' => 'firmware',
    'scsi-hd' => 'firmware',
    'virtio-blk-ccw' => 'firmware',
    'virtio-net-ccw' => 'firmware',
};
my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(
    kvm_device_ipl_methods => sub {
        my ($binary, $types) = @_;
        return { map { $_ => $qemu_mod_ipl_methods->{$_} // 'none' } @$types };
    },
);

my $format_tests = [
    ['virtio0', { device => 'virtio0' }],
    ['device=net0,loadparm=1', { device => 'net0', loadparm => '1' }],
    ['scsi1,loadparm=0A01M 1', { device => 'scsi1', loadparm => '0A01M 1' }],
    ['virtio0,loadparm=12345678', { device => 'virtio0', loadparm => '12345678' }],
    ['virtio0,loadparm=abc', undef],
    ['virtio0,loadparm=123456789', undef],
    ['virtio0,loadparm=A-B', undef],
    ['loadparm=1', undef],
];

for my $test ($format_tests->@*) {
    my ($value, $expected) = $test->@*;
    my $ipl = eval { PVE::QemuServer::IPL::parse_ipl($value) };
    if ($expected) {
        is_deeply($ipl, $expected, "ipl '$value' is valid");
    } else {
        ok(!$ipl && $@, "ipl '$value' is invalid");
    }
}

my $conf = {
    arch => 's390x',
    efidisk0 => 'local:8006/vm-8006-disk-9.qcow2,size=1M',
    ide0 => 'local:8006/vm-8006-disk-8.qcow2,size=8G',
    net0 => 'virtio=BC:24:11:00:00:00,bridge=vmbr0',
    net1 => 'e1000=BC:24:11:00:00:01,bridge=vmbr0',
    net2 => 'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0400',
    scsi0 => 'local:8006/vm-8006-disk-1.qcow2,size=8G',
    scsi1 => 'local:iso/mf-install.iso,media=cdrom',
    scsi2 => 'local:8006/vm-8006-cloudinit.qcow2,media=cdrom',
    scsihw => 'virtio-scsi-single',
    virtio0 => 'local:8006/vm-8006-disk-0.qcow2,size=8G',
};

is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices($conf, undef, '/usr/bin/kvm'),
    [
        {
            key => 'net0',
            type => 'virtio-net-ccw',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0012',
            description => 'network device BC:24:11:00:00:00, bridge vmbr0',
        },
        {
            key => 'scsi0',
            type => 'scsi-hd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0061',
            description => 'disk local:8006/vm-8006-disk-1.qcow2',
        },
        {
            key => 'scsi1',
            type => 'scsi-cd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0062',
            description => 'CD-ROM local:iso/mf-install.iso',
        },
        {
            key => 'virtio0',
            type => 'virtio-blk-ccw',
            'ipl-method' => 'firmware',
            devno => 'fe.0.000a',
            description => 'disk local:8006/vm-8006-disk-0.qcow2',
        },
    ],
    'IPL devices: virtio and SCSI disks and CD-ROMs, virtio NICs; no cloud-init, EFI, IDE, e1000'
        . ' or qeth (QEMU-mod cannot IPL from qeth)',
);

is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices(
        {
            arch => 's390x',
            scsi0 => 'local:8006/vm-8006-disk-1.qcow2,size=8G',
            tape0 => 'local:iso/SYSTEM.AWS',
            tape2 => 'none,devno=0.0.0590',
        },
        undef,
        '/usr/bin/kvm',
    ),
    [
        {
            key => 'scsi0',
            type => 'scsi-hd',
            'ipl-method' => 'firmware',
            devno => 'fe.0.0005',
            description => 'disk local:8006/vm-8006-disk-1.qcow2',
        },
        {
            key => 'tape0',
            type => '3590-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0580',
            description => 'tape drive, local:iso/SYSTEM.AWS',
        },
        {
            key => 'tape2',
            type => '3590-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0590',
            description => 'tape drive, empty',
        },
    ],
    'IPL devices: tape drives, also empty ones; virtio SCSI controller by default',
);

{
    local $qemu_mod_ipl_methods->{'qeth-ccw'} = 'ccw';
    my ($qeth) = grep { $_->{key} eq 'net2' }
        PVE::QemuServer::IPL::get_ipl_devices($conf, undef, '/usr/bin/kvm')->@*;
    is_deeply(
        $qeth,
        {
            key => 'net2',
            type => 'qeth-ccw',
            'ipl-method' => 'ccw',
            devno => 'fe.0.0400',
            description => 'network device BC:24:11:00:00:02, bridge vmbr0',
        },
        'a qeth adapter is an IPL device at its configured device number if QEMU can IPL from it',
    );
}

ok(
    PVE::QemuServer::IPL::ipl_with_bootindex({ 'ipl-method' => 'firmware' }),
    "IPL method 'firmware' uses bootindex",
);
ok(
    !PVE::QemuServer::IPL::ipl_with_bootindex({ 'ipl-method' => 'ccw' }),
    "IPL method 'ccw' is a channel-program IPL",
);

$helpers->unmock('kvm_device_ipl_methods');

# a QEMU binary answering device-list-properties: QEMU-mod types with the 'iplable' and
# 'ipl-method' properties, a type without them as in QEMU, and an unknown type
my $qmp_output = <<'EOF';
{"QMP": {"version": {}, "capabilities": []}}
{"return": {}}
{"return": [{"name": "devno", "type": "str"}, {"name": "iplable", "type": "bool", "default-value": true}, {"name": "ipl-method", "type": "string", "default-value": "ccw"}], "id": "fba-ccw"}
{"return": [{"name": "iplable", "type": "bool", "default-value": false}, {"name": "ipl-method", "type": "string", "default-value": "none"}], "id": "virtio-scsi-ccw"}
{"return": [{"name": "iplable", "type": "bool", "default-value": true}, {"name": "ipl-method", "type": "string", "default-value": "firmware"}], "id": "virtio-blk-ccw"}
{"return": [{"name": "drive", "type": "str"}], "id": "scsi-hd"}
{"return": [{"name": "drive", "type": "str"}], "id": "qeth-ccw"}
{"error": {"class": "GenericError", "desc": "Device 'x-unknown' not found"}, "id": "x-unknown"}
{"return": {}}
EOF

my $dir = tempdir(CLEANUP => 1);
my $binary = "$dir/kvm-ipl";
file_set_contents($binary, "#!/bin/sh\ncat >/dev/null\ncat <<'EOF'\n${qmp_output}EOF\n", 0755);
is_deeply(
    PVE::QemuServer::Helpers::kvm_device_ipl_methods(
        $binary,
        [qw(fba-ccw virtio-scsi-ccw virtio-blk-ccw scsi-hd qeth-ccw x-unknown)],
    ),
    {
        'fba-ccw' => 'ccw',
        'virtio-scsi-ccw' => 'none',
        'virtio-blk-ccw' => 'firmware',
        'scsi-hd' => 'firmware', # no properties, as in QEMU: default
        'qeth-ccw' => 'none',
        'x-unknown' => 'none',
    },
    'IPL methods from device-list-properties, defaults without the properties',
);

done_testing();
