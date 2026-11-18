package PVE::QemuServer::IPL;

# IPL (initial program load) of s390x VMs with a mainframe operating system: the VM is started
# from one CCW device, selected with the 'ipl' option, instead of the boot order.

use strict;
use warnings;

use PVE::JSONSchema qw(parse_property_string);

use PVE::QemuServer::Drive;
use PVE::QemuServer::DriveDevice qw(scsihw_infos);
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Network;
use PVE::QemuServer::PCI qw(print_pci_addr);

my $ipl_fmt = {
    device => {
        default_key => 1,
        type => 'string',
        pattern => '[a-z]+\d+',
        format_description => 'device',
        description => "The device to IPL from, the key of a disk, CD-ROM drive or network"
            . " device of the VM whose QEMU device can IPL, for example 'virtio0'.",
    },
    loadparm => {
        optional => 1,
        type => 'string',
        pattern => '[A-Z0-9. ]{0,8}',
        format_description => 'loadparm',
        description => "The load parameter for the IPL, up to 8 characters A-Z, 0-9, '.' and"
            . " space. Its meaning depends on the operating system.",
    },
};
PVE::JSONSchema::register_format('pve-qm-ipl', $ipl_fmt);

sub parse_ipl {
    my ($value) = @_;
    return parse_property_string($ipl_fmt, $value);
}

# The devno of a virtio CCW device, from the print_pci_addr() of its id.
my sub virtio_devno {
    my ($id) = @_;
    my $addr = print_pci_addr($id, 's390x');
    return $addr =~ m/devno=([0-9a-f.]+)/ ? $1 : undef;
}

# The devices of a VM config that the QEMU binary can IPL from, sorted by key. Each entry has the
# config 'key', the QEMU device 'type' qemu-server generates for it, the 'devno' of the CCW device
# that IPLs (for SCSI devices, that of their virtio-scsi-ccw controller), the 'ccw-type' of that
# device and a 'description'.
sub get_ipl_devices {
    my ($conf, $storecfg, $kvm_binary) = @_;

    my $res = [];

    for my $key (sort keys %$conf) {
        next if !PVE::QemuServer::Drive::is_valid_drivename($key);
        my $drive = PVE::QemuServer::Drive::parse_drive($key, $conf->{$key}) or next;

        next if $drive->{interface} eq 'efidisk' || $drive->{interface} eq 'tpmstate';
        next if PVE::QemuServer::Drive::drive_is_cloudinit($drive);

        my $cdrom = PVE::QemuServer::Drive::drive_is_cdrom($drive);
        my $entry;
        if ($drive->{interface} eq 'virtio') {
            $entry = {
                type => 'virtio-blk-ccw',
                'ccw-type' => 'virtio-blk-ccw',
                devno => virtio_devno($key),
            };
        } elsif ($drive->{interface} eq 'scsi') {
            my $scsi_type =
                eval { PVE::QemuServer::Drive::get_scsi_device_type($drive, $storecfg, undef) }
                // ($cdrom ? 'cd' : 'hd');
            my (undef, $controller, $prefix) = scsihw_infos($conf->{scsihw}, $drive->{index});
            $entry = {
                type => "scsi-$scsi_type",
                'ccw-type' => 'virtio-scsi-ccw',
                devno => virtio_devno("$prefix$controller"),
            };
        } else {
            next; # no CCW device (IDE, SATA)
        }
        $entry->{key} = $key;
        $entry->{description} = ($cdrom ? 'CD-ROM' : 'disk') . " $drive->{file}";
        push @$res, $entry;
    }

    for my $key (sort keys %$conf) {
        next if $key !~ m/^net\d+$/;
        my $net = eval { PVE::QemuServer::Network::parse_net($conf->{$key}) } or next;
        next if $net->{model} ne 'virtio';
        my $description = "network device $net->{macaddr}";
        $description .= ", bridge $net->{bridge}" if $net->{bridge};
        push @$res,
            {
                key => $key,
                type => 'virtio-net-ccw',
                'ccw-type' => 'virtio-net-ccw',
                devno => virtio_devno($key),
                description => $description,
            };
    }

    $res = [
        grep {
            defined($_->{devno})
                && PVE::QemuServer::Helpers::kvm_device_can_ipl($kvm_binary, $_->{'ccw-type'})
        } @$res
    ];

    return [sort { $a->{key} cmp $b->{key} } @$res];
}

# Check the 'ipl' option of a config and return it, together with the device to IPL from.
sub check_ipl_config {
    my ($conf, $storecfg, $kvm_binary) = @_;

    my $ipl = parse_ipl($conf->{ipl});
    my $key = $ipl->{device};

    die "ipl: only supported on s390x\n"
        if PVE::QemuServer::Helpers::get_vm_arch($conf) ne 's390x';
    die "ipl: device '$key' does not exist\n" if !$conf->{$key};

    $kvm_binary //= PVE::QemuServer::Helpers::get_command_for_arch('s390x');
    my ($device) = grep { $_->{key} eq $key } get_ipl_devices($conf, $storecfg, $kvm_binary)->@*;
    die "ipl: cannot IPL from '$key'\n" if !$device;

    return ($ipl, $device);
}

# virtio devices, also SCSI devices on virtio-scsi, IPL with the s390-ccw firmware, selected with
# bootindex. Other CCW devices do a channel-program IPL, selected with the machine 'ipl' property.
sub ipl_with_bootindex {
    my ($device) = @_;
    return $device->{'ccw-type'} =~ m/^virtio-/;
}

1;
