#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;

use PVE::QemuServer::IPL;

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
            'ccw-type' => 'virtio-net-ccw',
            devno => 'fe.0.0012',
            description => 'network device BC:24:11:00:00:00, bridge vmbr0',
        },
        {
            key => 'scsi0',
            type => 'scsi-hd',
            'ccw-type' => 'virtio-scsi-ccw',
            devno => 'fe.0.0061',
            description => 'disk local:8006/vm-8006-disk-1.qcow2',
        },
        {
            key => 'scsi1',
            type => 'scsi-cd',
            'ccw-type' => 'virtio-scsi-ccw',
            devno => 'fe.0.0062',
            description => 'CD-ROM local:iso/mf-install.iso',
        },
        {
            key => 'virtio0',
            type => 'virtio-blk-ccw',
            'ccw-type' => 'virtio-blk-ccw',
            devno => 'fe.0.000a',
            description => 'disk local:8006/vm-8006-disk-0.qcow2',
        },
    ],
    'IPL devices: virtio and SCSI disks and CD-ROMs, virtio NICs; no cloud-init, EFI, IDE or e1000',
);

ok(
    PVE::QemuServer::IPL::ipl_with_bootindex({ 'ccw-type' => 'virtio-scsi-ccw' }),
    'virtio devices IPL with bootindex',
);
ok(
    !PVE::QemuServer::IPL::ipl_with_bootindex({ 'ccw-type' => 'eckd-ccw' }),
    'other CCW devices do a channel-program IPL',
);

done_testing();
