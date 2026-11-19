package PVE::QemuServer::Drive;

use strict;
use warnings;

use IO::File;
use List::Util qw(first);
use Storable qw(dclone);

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTEnvironment qw(log_warn);
use PVE::Storage;
use PVE::Storage::Common;
use PVE::Tools;

use PVE::QemuServer::CCW;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(qsd_qmp_peer vm_qmp_peer);

use base qw(Exporter);

our @EXPORT_OK = qw(
    is_valid_drivename
    checked_parse_volname
    checked_volume_format
    classify_drive_file
    drive_has_absolute_path
    drive_is_cloudinit
    drive_is_cdrom
    parse_drive
    print_drive
    storage_allows_io_uring_default
    update_tpmstate_size
    get_tpmstate_size
);

my $DROPPED_PROPERTIES = ['cyls', 'heads', 'secs', 'trans'];

our $QEMU_FORMAT_RE = qr/raw|qcow|qcow2|qed|vmdk|cloop/;

PVE::JSONSchema::register_standard_option(
    'pve-qm-image-format',
    {
        type => 'string',
        enum => [qw(raw qcow qed qcow2 vmdk cloop)],
        description => "The drive's backing file's data format.",
        optional => 1,
    },
);

# Check that a volume can be used for image-related operations with QEMU, in
# particular, attached as VM image or ISO, used for qemu-img, or (live-)imported.
# NOTE Currently, this helper cannot be used for backups.
# TODO allow configuring certain restrictions via $opts argument, e.g. expected vtype?
sub checked_parse_volname {
    my ($storecfg, $volid) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        PVE::Storage::parse_volname($storecfg, $volid);

    if ($vtype eq 'import') {
        die "unable to parse format for import volume '$volid'\n" if !$format;
        if ($format =~ m/^ova\+(.*)$/) {
            my $extracted_format = $1;
            die "volume '$volid' - unknown import format '$format'\n"
                if $extracted_format !~ m/^($QEMU_FORMAT_RE)$/;
            return ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format);
        }
    }

    # TODO PVE 9 - consider switching to die for an undefined format
    $format = 'raw' if !defined($format);

    die "volume '$volid' - not a QEMU image format '$format'\n"
        if $format !~ m/^($QEMU_FORMAT_RE)$/;

    # For iso content type, no format is returned yet.

    return ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format);
}

sub checked_volume_format {
    my ($storecfg, $volid) = @_;

    return (checked_parse_volname($storecfg, $volid))[6];
}

my $cdrom_path;

sub get_cdrom_path {
    return $cdrom_path if defined($cdrom_path);

    $cdrom_path = first { -l $_ } map { "/dev/cdrom$_" } ('', '1', '2');

    if (!defined($cdrom_path)) {
        log_warn("no physical CD-ROM available, ignoring");
        $cdrom_path = '';
    }

    return $cdrom_path;
}

sub get_iso_path {
    my ($storecfg, $cdrom) = @_;

    if ($cdrom eq 'cdrom') {
        return get_cdrom_path();
    } elsif ($cdrom eq 'none') {
        return '';
    } elsif ($cdrom =~ m|^/|) {
        return $cdrom;
    } else {
        return PVE::Storage::path($storecfg, $cdrom);
    }
}

# Returns the path that can be used on the QEMU commandline and in QMP commands as well as the
# checked format of the drive.
sub get_path_and_format {
    my ($storecfg, $drive, $live_restore_name) = @_;

    my $path;
    my $volid = $drive->{file};
    my $drive_id = get_drive_id($drive);

    my ($storeid) = PVE::Storage::parse_volume_id($volid, 1);

    if (drive_is_cdrom($drive)) {
        $path = get_iso_path($storecfg, $volid);
        die "$drive_id: cannot back cdrom drive with a live restore image\n" if $live_restore_name;
    } else {
        if ($storeid) {
            $path = PVE::Storage::path($storecfg, $volid);
        } else {
            $path = $volid;
        }
    }

    # For PVE-managed volumes, use the format from the storage layer and prevent overrides via the
    # drive's 'format' option. For unmanaged volumes, fallback to 'raw' to avoid auto-detection by
    # QEMU. For the special case 'none' (get_iso_path() returns an empty $path), there should be no
    # format or QEMU won't start.
    my $format;
    if (drive_is_cdrom($drive) && !$path) {
        # no format
    } elsif ($storeid) {
        $format = checked_volume_format($storecfg, $volid);

        if ($drive->{format} && $drive->{format} ne $format) {
            die "drive '$drive_id' - volume '$volid' - 'format=$drive->{format}' option different"
                . " from storage format '$format'\n";
        }
    } else {
        $format = $drive->{format} // 'raw';
    }

    return ($path, $format);
}

my $MAX_IDE_DISKS = 4;
our $MAX_SCSI_DISKS = 31;
my $MAX_VIRTIO_DISKS = 16;
my $MAX_FBA_DISKS = 32;
my $MAX_CKD_DISKS = 64;
our $MAX_SATA_DISKS = 6;
our $MAX_UNUSED_DISKS = 256;
our $NEW_DISK_RE = qr!^(([^/:\s]+):)?(\d+(\.\d+)?)$!;

our $drivedesc_hash;
# Schema when disk allocation is possible.
our $drivedesc_hash_with_alloc = {};

my %drivedesc_base = (
    volume => { alias => 'file' },
    file => {
        type => 'string',
        format => 'pve-volume-id-or-qm-path',
        default_key => 1,
        format_description => 'volume',
        description => "The drive's backing volume.",
    },
    media => {
        type => 'string',
        enum => [qw(cdrom disk)],
        description => "The drive's media type.",
        default => 'disk',
        optional => 1,
    },
    snapshot => {
        type => 'boolean',
        description => "Controls qemu's snapshot mode feature."
            . " If activated, changes made to the disk are temporary and will"
            . " be discarded when the VM is shutdown.",
        optional => 1,
    },
    cache => {
        type => 'string',
        enum => [qw(none writethrough writeback unsafe directsync)],
        description => "The drive's cache mode",
        optional => 1,
    },
    format => get_standard_option('pve-qm-image-format'),
    size => {
        type => 'string',
        format => 'disk-size',
        format_description => 'DiskSize',
        description => "Disk size. This is purely informational and has no effect.",
        optional => 1,
    },
    backup => {
        type => 'boolean',
        description => "Whether the drive should be included when making backups.",
        optional => 1,
    },
    replicate => {
        type => 'boolean',
        description => 'Whether the drive should considered for replication jobs.',
        optional => 1,
        default => 1,
    },
    rerror => {
        type => 'string',
        enum => [qw(ignore report stop)],
        description => 'Read error action.',
        optional => 1,
    },
    werror => {
        type => 'string',
        enum => [qw(enospc ignore report stop)],
        description => 'Write error action.',
        optional => 1,
    },
    aio => {
        type => 'string',
        enum => [qw(native threads io_uring)],
        description => 'AIO type to use.',
        optional => 1,
    },
    discard => {
        type => 'string',
        enum => [qw(ignore on)],
        description =>
            'Controls whether to pass discard/trim requests to the underlying storage.',
        optional => 1,
    },
    detect_zeroes => {
        type => 'boolean',
        description => 'Controls whether to detect and try to optimize writes of zeroes.',
        optional => 1,
    },
    serial => {
        type => 'string',
        format => 'urlencoded',
        format_description => 'serial',
        maxLength => 20 * 3, # *3 since it's %xx url enoded
        description => "The drive's reported serial number, url-encoded, up to 20 bytes long.",
        optional => 1,
    },
    shared => {
        type => 'boolean',
        description => 'Mark this locally-managed volume as available on all nodes',
        verbose_description =>
            "Mark this locally-managed volume as available on all nodes.\n\nWARNING: This option does not share the volume automatically, it assumes it is shared already!",
        optional => 1,
        default => 0,
    },
);

my %iothread_fmt = (
    iothread => {
        type => 'boolean',
        description => "Whether to use iothreads for this drive",
        optional => 1,
    },
);

my %product_fmt = (
    product => {
        type => 'string',
        pattern => '[A-Za-z0-9\-_\s]{,16}', # QEMU (8.1) will quietly only use 16 bytes
        format_description => 'product',
        description => "The drive's product name, up to 16 bytes long.",
        optional => 1,
    },
);

my %vendor_fmt = (
    vendor => {
        type => 'string',
        pattern => '[A-Za-z0-9\-_\s]{,8}', # QEMU (8.1) will quietly only use 8 bytes
        format_description => 'vendor',
        description => "The drive's vendor name, up to 8 bytes long.",
        optional => 1,
    },
);

my %model_fmt = (
    model => {
        type => 'string',
        format => 'urlencoded',
        format_description => 'model',
        maxLength => 40 * 3, # *3 since it's %xx url enoded
        description => "The drive's reported model name, url-encoded, up to 40 bytes long.",
        optional => 1,
    },
);

my %queues_fmt = (
    queues => {
        type => 'integer',
        description => "Number of queues.",
        minimum => 2,
        optional => 1,
    },
);

my %readonly_fmt = (
    ro => {
        type => 'boolean',
        description => "Whether the drive is read-only.",
        optional => 1,
    },
);

my %scsiblock_fmt = (
    scsiblock => {
        type => 'boolean',
        description =>
            "whether to use scsi-block for full passthrough of host block device\n\nWARNING: can lead to I/O errors in combination with low memory or high memory fragmentation on host",
        optional => 1,
        default => 0,
    },
);

my %ssd_fmt = (
    ssd => {
        type => 'boolean',
        description =>
            "Whether to expose this drive as an SSD, rather than a rotational hard disk.",
        optional => 1,
    },
);

my %wwn_fmt = (
    wwn => {
        type => 'string',
        pattern => qr/^(0x)[0-9a-fA-F]{16}/,
        format_description => 'wwn',
        description =>
            "The drive's worldwide name, encoded as 16 bytes hex string, prefixed by '0x'.",
        optional => 1,
    },
);

my $add_throttle_desc = sub {
    my ($key, $type, $what, $unit, $longunit, $minimum) = @_;
    my $d = {
        type => $type,
        format_description => $unit,
        description => "Maximum $what in $longunit.",
        optional => 1,
    };
    $d->{minimum} = $minimum if defined($minimum);
    $drivedesc_base{$key} = $d;
};
# throughput: (leaky bucket)
$add_throttle_desc->('bps', 'integer', 'r/w speed', 'bps', 'bytes per second');
$add_throttle_desc->('bps_rd', 'integer', 'read speed', 'bps', 'bytes per second');
$add_throttle_desc->('bps_wr', 'integer', 'write speed', 'bps', 'bytes per second');
$add_throttle_desc->('mbps', 'number', 'r/w speed', 'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_rd', 'number', 'read speed', 'mbps', 'megabytes per second');
$add_throttle_desc->('mbps_wr', 'number', 'write speed', 'mbps', 'megabytes per second');
$add_throttle_desc->('iops', 'integer', 'r/w I/O', 'iops', 'operations per second');
$add_throttle_desc->('iops_rd', 'integer', 'read I/O', 'iops', 'operations per second');
$add_throttle_desc->('iops_wr', 'integer', 'write I/O', 'iops', 'operations per second');
# Only kept for existing configs, as an unknown key would invalidate the whole drive.
for my $opt (qw(bps bps_rd bps_wr)) {
    $drivedesc_base{$opt}->{description} .= " Deprecated: Use 'm$opt' instead.";
}

# pools: (pool of IO before throttling starts taking effect)
$add_throttle_desc->('mbps_max', 'number', 'unthrottled r/w pool', 'mbps', 'megabytes per second');
$add_throttle_desc->(
    'mbps_rd_max',
    'number',
    'unthrottled read pool',
    'mbps',
    'megabytes per second',
);
$add_throttle_desc->(
    'mbps_wr_max',
    'number',
    'unthrottled write pool',
    'mbps',
    'megabytes per second',
);
$add_throttle_desc->(
    'iops_max',
    'integer',
    'unthrottled r/w I/O pool',
    'iops',
    'operations per second',
);
$add_throttle_desc->(
    'iops_rd_max',
    'integer',
    'unthrottled read I/O pool',
    'iops',
    'operations per second',
);
$add_throttle_desc->(
    'iops_wr_max',
    'integer',
    'unthrottled write I/O pool',
    'iops',
    'operations per second',
);

# burst lengths
$add_throttle_desc->('bps_max_length', 'integer', 'length of I/O bursts', 'seconds', 'seconds', 1);
$add_throttle_desc->(
    'bps_rd_max_length',
    'integer',
    'length of read I/O bursts',
    'seconds',
    'seconds',
    1,
);
$add_throttle_desc->(
    'bps_wr_max_length',
    'integer',
    'length of write I/O bursts',
    'seconds',
    'seconds',
    1,
);
$add_throttle_desc->('iops_max_length', 'integer', 'length of I/O bursts', 'seconds', 'seconds', 1);
$add_throttle_desc->(
    'iops_rd_max_length',
    'integer',
    'length of read I/O bursts',
    'seconds',
    'seconds',
    1,
);
$add_throttle_desc->(
    'iops_wr_max_length',
    'integer',
    'length of write I/O bursts',
    'seconds',
    'seconds',
    1,
);

# legacy support
$drivedesc_base{'bps_rd_length'} = { alias => 'bps_rd_max_length' };
$drivedesc_base{'bps_wr_length'} = { alias => 'bps_wr_max_length' };
$drivedesc_base{'iops_rd_length'} = { alias => 'iops_rd_max_length' };
$drivedesc_base{'iops_wr_length'} = { alias => 'iops_wr_max_length' };

my $ide_fmt = {
    %drivedesc_base, %model_fmt, %ssd_fmt, %wwn_fmt,
};
PVE::JSONSchema::register_format("pve-qm-ide", $ide_fmt);

my $idedesc = {
    optional => 1,
    type => 'string',
    format => $ide_fmt,
    description => "Use volume as IDE hard disk or CD-ROM (n is 0 to "
        . ($MAX_IDE_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-ide", $idedesc);

my $scsi_fmt = {
    %drivedesc_base,
    %iothread_fmt,
    %product_fmt,
    %queues_fmt,
    %readonly_fmt,
    %scsiblock_fmt,
    %ssd_fmt,
    %vendor_fmt,
    %wwn_fmt,
};
my $scsidesc = {
    optional => 1,
    type => 'string',
    format => $scsi_fmt,
    description => "Use volume as SCSI hard disk or CD-ROM (n is 0 to "
        . ($MAX_SCSI_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-scsi", $scsidesc);

my $sata_fmt = {
    %drivedesc_base, %ssd_fmt, %wwn_fmt,
};
my $satadesc = {
    optional => 1,
    type => 'string',
    format => $sata_fmt,
    description => "Use volume as SATA hard disk or CD-ROM (n is 0 to "
        . ($MAX_SATA_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-sata", $satadesc);

my $virtio_fmt = {
    %drivedesc_base, %iothread_fmt, %readonly_fmt,
};
my $virtiodesc = {
    optional => 1,
    type => 'string',
    format => $virtio_fmt,
    description => "Use volume as VIRTIO hard disk (n is 0 to "
        . ($MAX_VIRTIO_DISKS - 1) . ").",
};
PVE::JSONSchema::register_standard_option("pve-qm-virtio", $virtiodesc);

# DASDs of s390x, channel-attached disks addressed by their device number. Only the options that
# apply to them, the device itself has no cache, discard or error policy settings.
my %dasd_fmt = (
    devno => {
        type => 'string',
        format => 'pve-qm-ccw-devno',
        format_description => 'devno',
        description => "The device number the guest addresses the DASD with, 0.<ssid>.<devno>"
            . " (for example 0.0.0200). Assigned from the default range of the device type when"
            . " creating the disk, if not given.",
        optional => 1,
    },
    # Identity override for special cases (CLI/config only): a guest that needs to see another
    # device or control unit type than the emulated one, like a 3380 on 3390 geometry, as the
    # storage arrays offered it for old operating systems.
    devtype => {
        type => 'string',
        format => 'pve-qm-dasd-identity',
        format_description => 'TTTT[-MM]',
        description => "Expert option: the device type the guest sees in the device"
            . " identification (Sense ID), instead of the emulated device's: the type in hex"
            . " and optionally the model, as a model name (3380-A, -D, -J, -E, -K; 3390-1, -2,"
            . " -3, -9, -27, -54, -A) or as the model byte of the Sense ID in hex (two digits,"
            . " for example 3380-1e). Without a model, QEMU derives it for 3380 and 3390 from the"
            . " cylinders. The geometry and the commands stay those of the emulated device."
            . " Needs a QEMU build with the 'device-type' property of the DASD device.",
        optional => 1,
    },
    cutype => {
        type => 'string',
        format => 'pve-qm-dasd-identity',
        format_description => 'TTTT[-MM]',
        description => "Expert option: the control unit type the guest sees in the device"
            . " identification (Sense ID): the type in hex and optionally the model, as a model"
            . " name (3990-6) or as the model byte of the Sense ID in hex (two digits, for"
            . " example 3990-e9, 2107-e8). Without a model, QEMU derives it for 2105, 2107 (E8)"
            . " and 3990 (E9, the 3990-6). Needs a QEMU build with the 'control-unit-type'"
            . " property of the DASD device.",
        optional => 1,
    },
);

# The model names of the DASD identity override ('devtype', 'cutype'): the Sense ID model bytes of
# the usual designations (as QEMU derives them from the cylinders, see QEMU-mod's eckd-ccw).
# 3390-9, -27, -54 and -A all report 0x0c. A name takes precedence over a hex byte of the same
# spelling (3390-27 is the model 27, not the byte 0x27).
my $dasd_model_names = {
    3380 => { A => 0x02, D => 0x02, J => 0x02, E => 0x0a, K => 0x1e },
    3390 => { 1 => 0x02, 2 => 0x06, 3 => 0x0a, 9 => 0x0c, 27 => 0x0c, 54 => 0x0c, A => 0x0c },
    3990 => { 6 => 0xe9 },
};

# Parse a DASD identity 'TTTT[-MM]': returns the type and the model (undef: derived), as numbers.
sub parse_dasd_identity {
    my ($value) = @_;

    my ($type, $model) = $value =~ m/^([0-9a-fA-F]{4})(?:-([0-9a-zA-Z]{1,2}))?$/
        or die "invalid identity '$value', expected TTTT[-MM] (type in hex, model)\n";
    return (hex($type), undef) if !defined($model);
    my $names = $dasd_model_names->{ lc($type) } // {};
    my $byte = $names->{ uc($model) };
    if (!defined($byte)) {
        die "unknown model '$model' of $type, expected "
            . (%$names ? join(', ', sort keys %$names) . ' or ' : '')
            . "the model byte in hex (two digits)\n"
            if $model !~ m/^[0-9a-fA-F]{2}$/;
        $byte = hex($model);
    }
    die "invalid model '$model' of $type: the model byte 00 means 'derive', leave it out\n"
        if !$byte;
    return (hex($type), $byte);
}

PVE::JSONSchema::register_format(
    'pve-qm-dasd-identity',
    sub {
        my ($value, $noerr) = @_;
        eval { parse_dasd_identity($value) };
        if (my $err = $@) {
            return undef if $noerr;
            die $err;
        }
        return $value;
    },
);

# 'media' only for a cloud-init drive, which is an FBA DASD on s390x
my $fba_fmt = {
    %drivedesc_base{qw(volume file media format size backup replicate shared)},
    %readonly_fmt,
    %dasd_fmt,
    model => {
        type => 'string',
        enum => [qw(9336)],
        description => "The device model of the DASD. Set when the volume is created or"
            . " imported, informational.",
        optional => 1,
    },
};
my $fbadesc = {
    optional => 1,
    type => 'string',
    format => $fba_fmt,
    description => "Use volume as s390x FBA DASD, an IBM 9336 fixed-block disk (n is 0 to "
        . ($MAX_FBA_DISKS - 1) . ").",
    verbose_description => "Use volume as s390x FBA DASD, an IBM 9336 fixed-block disk (n is 0"
        . " to "
        . ($MAX_FBA_DISKS - 1)
        . ").\n\nAn FBA DASD can be the cloud-init drive (media=cdrom)."
        . " Note that Linux does not set DASDs online by default, so the guest image must do"
        . " that for cloud-init to find the drive, for example with the kernel parameter"
        . " 'dasd=0.0.0200' (or 'dasd_mod.dasd=autodetect') or with chzdev.",
};
PVE::JSONSchema::register_standard_option("pve-qm-fba", $fbadesc);

my %ckd_fmt = (
    model => {
        type => 'string',
        enum => [qw(3390 3390-1 3390-2 3390-3 3390-9 3390-27 3390-54)],
        description => "The 3390 model of the volume, '3390' for a cylinder count of no standard"
            . " model. Set when the volume is created or imported. When creating a volume, its"
            . " size can be given as model instead of 'cylinders'.",
        optional => 1,
    },
    cylinders => {
        type => 'integer',
        minimum => 1,
        maximum => 65520,
        description =>
            "The number of cylinders of the 3390 volume. This is purely informational,"
            . " the volume header holds the size.",
        optional => 1,
    },
);

my $ckd_fmt = {
    %drivedesc_base{qw(volume file format size backup replicate shared)},
    %readonly_fmt, %dasd_fmt, %ckd_fmt,
};
my $ckddesc = {
    optional => 1,
    type => 'string',
    format => $ckd_fmt,
    description => "Use volume as s390x CKD DASD, an IBM 3390 count-key-data disk (n is 0 to "
        . ($MAX_CKD_DISKS - 1)
        . "). The channel programs of the guest do synchronous I/O, so CKD volumes on network"
        . " storage (Ceph RBD, NFS) are slow; prefer local ZFS or LVM storage.",
};
PVE::JSONSchema::register_standard_option("pve-qm-ckd", $ckddesc);

# Only when allocating a new DASD volume.
my %dasd_alloc_fmt = (
    name => {
        type => 'string',
        pattern => '[A-Za-z0-9][A-Za-z0-9_-]{0,39}',
        format_description => 'name',
        description => "Name of the new volume, it is called 'vm-<vmid>-<name>' on the"
            . " storage. For example the volume serial (VOLSER) the guest will give the volume.",
        optional => 1,
    },
);

my %efitype_fmt = (
    efitype => {
        type => 'string',
        enum => [qw(2m 4m)],
        description => "Size and type of the OVMF EFI vars. '4m' is newer and recommended,"
            . " and required for Secure Boot. For backwards compatibility, '2m' is used"
            . " if not otherwise specified. Ignored for VMs with arch=aarch64 (ARM).",
        optional => 1,
        default => '2m',
    },
    'pre-enrolled-keys' => {
        type => 'boolean',
        description =>
            "Use am EFI vars template with distribution-specific and Microsoft Standard"
            . " keys enrolled, if used with 'efitype=4m'. Note that this will enable Secure Boot by"
            . " default, though it can still be turned off from within the VM.",
        optional => 1,
        default => 0,
    },
    'ms-cert' => {
        type => 'string',
        enum => [qw(2011 2023 2023w 2023k)],
        description =>
            "Informational marker indicating the version of the latest Microsoft UEFI certificates"
            . " that have been enrolled by Proxmox VE. The value '2023k' means that the 'Microsoft"
            . " UEFI CA 2023', the 'Windows UEFI CA 2023' and the 'Microsoft Corporation KEK 2K CA"
            . " 2023' certificates are included. The values '2023' and '2023w' are"
            . " deprecated and for compatibility only.",
        optional => 1,
        default => '2011',
    },
);

my $efidisk_fmt = {
    volume => { alias => 'file' },
    file => {
        type => 'string',
        format => 'pve-volume-id-or-qm-path',
        default_key => 1,
        format_description => 'volume',
        description => "The drive's backing volume.",
    },
    format => get_standard_option('pve-qm-image-format'),
    size => {
        type => 'string',
        format => 'disk-size',
        format_description => 'DiskSize',
        description => "Disk size. This is purely informational and has no effect.",
        optional => 1,
    },
    %efitype_fmt,
};

my $efidisk_desc = {
    optional => 1,
    type => 'string',
    format => $efidisk_fmt,
    description => "Configure a disk for storing EFI vars.",
};

PVE::JSONSchema::register_standard_option("pve-qm-efidisk", $efidisk_desc);

my %tpmversion_fmt = (
    version => {
        type => 'string',
        enum => [qw(v1.2 v2.0)],
        description => "The TPM interface version. v2.0 is newer and should be preferred."
            . " Note that this cannot be changed later on.",
        optional => 1,
        default => 'v1.2',
    },
);
my $tpmstate_fmt = {
    volume => { alias => 'file' },
    file => {
        type => 'string',
        format => 'pve-volume-id-or-qm-path',
        default_key => 1,
        format_description => 'volume',
        description => "The drive's backing volume.",
    },
    format => get_standard_option('pve-vm-image-format', { optional => 1 }),
    size => {
        type => 'string',
        format => 'disk-size',
        format_description => 'DiskSize',
        description => "Disk size. This is purely informational and has no effect.",
        optional => 1,
    },
    %tpmversion_fmt,
};
my $tpmstate_desc = {
    optional => 1,
    type => 'string',
    format => $tpmstate_fmt,
    description => "Configure a Disk for storing TPM state. The format is fixed to 'raw'.",
};
use constant TPMSTATE_DISK_SIZE => 4 * 1024 * 1024;

my $alldrive_fmt = {
    %drivedesc_base,
    %iothread_fmt,
    %product_fmt,
    %queues_fmt,
    %readonly_fmt,
    %scsiblock_fmt,
    %ssd_fmt,
    %vendor_fmt,
    %wwn_fmt,
    %tpmversion_fmt,
    %efitype_fmt,
    %dasd_fmt,
    %ckd_fmt,
    %model_fmt, # 'model' of all drive types for printing, the drive types check their own
};

my %import_from_fmt = (
    'import-from' => {
        type => 'string',
        format => 'pve-volume-id-or-absolute-path',
        format_description => 'source volume',
        description => "Create a new disk, importing from this source (volume ID or absolute "
            . "path). When an absolute path is specified, it's up to you to ensure that the source "
            . "is not actively used by another process during the import!",
        optional => 1,
    },
);

my $alldrive_fmt_with_alloc = {
    %$alldrive_fmt, %import_from_fmt, %dasd_alloc_fmt,
};

my $unused_fmt = {
    volume => { alias => 'file' },
    file => {
        type => 'string',
        format => 'pve-volume-id',
        default_key => 1,
        format_description => 'volume',
        description => "The drive's backing volume.",
    },
};

my $unuseddesc = {
    optional => 1,
    type => 'string',
    format => $unused_fmt,
    description =>
        "Reference to unused volumes. This is used internally, and should not be modified manually.",
};

my $with_alloc_desc_cache = {
    unused => $unuseddesc, # Allocation for unused is not supported currently.
};
my $desc_with_alloc = sub {
    my ($type, $desc) = @_;

    return $with_alloc_desc_cache->{$type} if $with_alloc_desc_cache->{$type};

    my $new_desc = dclone($desc);

    $new_desc->{format}->{'import-from'} = $import_from_fmt{'import-from'};
    $new_desc->{format}->{name} = $dasd_alloc_fmt{name} if $type eq 'fba' || $type eq 'ckd';

    my $extra_note = '';
    if ($type eq 'efidisk') {
        $extra_note =
            " Note that SIZE_IN_GiB is ignored here and that the default EFI vars are "
            . "copied to the volume instead.";
    } elsif ($type eq 'tpmstate') {
        $extra_note = " Note that SIZE_IN_GiB is ignored here and 4 MiB will be used instead.";
    } elsif ($type eq 'ckd') {
        $extra_note = " Note that SIZE_IN_GiB is ignored here, the size comes from 'model' or"
            . " 'cylinders'.";
    }

    $new_desc->{description} .=
        " Use the special syntax STORAGE_ID:SIZE_IN_GiB to allocate a new "
        . "volume.${extra_note} Use STORAGE_ID:0 and the 'import-from' parameter to import from an "
        . "existing volume.";

    $with_alloc_desc_cache->{$type} = $new_desc;

    return $new_desc;
};

for (my $i = 0; $i < $MAX_IDE_DISKS; $i++) {
    $drivedesc_hash->{"ide$i"} = $idedesc;
    $drivedesc_hash_with_alloc->{"ide$i"} = $desc_with_alloc->('ide', $idedesc);
}

for (my $i = 0; $i < $MAX_SATA_DISKS; $i++) {
    $drivedesc_hash->{"sata$i"} = $satadesc;
    $drivedesc_hash_with_alloc->{"sata$i"} = $desc_with_alloc->('sata', $satadesc);
}

for (my $i = 0; $i < $MAX_SCSI_DISKS; $i++) {
    $drivedesc_hash->{"scsi$i"} = $scsidesc;
    $drivedesc_hash_with_alloc->{"scsi$i"} = $desc_with_alloc->('scsi', $scsidesc);
}

for (my $i = 0; $i < $MAX_VIRTIO_DISKS; $i++) {
    $drivedesc_hash->{"virtio$i"} = $virtiodesc;
    $drivedesc_hash_with_alloc->{"virtio$i"} = $desc_with_alloc->('virtio', $virtiodesc);
}

for (my $i = 0; $i < $MAX_FBA_DISKS; $i++) {
    $drivedesc_hash->{"fba$i"} = $fbadesc;
    $drivedesc_hash_with_alloc->{"fba$i"} = $desc_with_alloc->('fba', $fbadesc);
}

for (my $i = 0; $i < $MAX_CKD_DISKS; $i++) {
    $drivedesc_hash->{"ckd$i"} = $ckddesc;
    $drivedesc_hash_with_alloc->{"ckd$i"} = $desc_with_alloc->('ckd', $ckddesc);
}

$drivedesc_hash->{efidisk0} = $efidisk_desc;
$drivedesc_hash_with_alloc->{efidisk0} = $desc_with_alloc->('efidisk', $efidisk_desc);

$drivedesc_hash->{tpmstate0} = $tpmstate_desc;
$drivedesc_hash_with_alloc->{tpmstate0} = $desc_with_alloc->('tpmstate', $tpmstate_desc);

for (my $i = 0; $i < $MAX_UNUSED_DISKS; $i++) {
    $drivedesc_hash->{"unused$i"} = $unuseddesc;
    $drivedesc_hash_with_alloc->{"unused$i"} = $desc_with_alloc->('unused', $unuseddesc);
}

sub valid_drive_names_for_boot {
    return grep { $_ ne 'efidisk0' && $_ ne 'tpmstate0' } valid_drive_names();
}

sub valid_drive_names {
    # order is important - used to autoselect boot disk
    return (
        (map { "ide$_" } (0 .. ($MAX_IDE_DISKS - 1))),
        (map { "scsi$_" } (0 .. ($MAX_SCSI_DISKS - 1))),
        (map { "virtio$_" } (0 .. ($MAX_VIRTIO_DISKS - 1))),
        (map { "sata$_" } (0 .. ($MAX_SATA_DISKS - 1))),
        (map { "fba$_" } (0 .. ($MAX_FBA_DISKS - 1))),
        (map { "ckd$_" } (0 .. ($MAX_CKD_DISKS - 1))),
        'efidisk0',
        'tpmstate0',
    );
}

sub valid_drive_names_with_unused {
    return (valid_drive_names(), map { "unused$_" } (0 .. ($MAX_UNUSED_DISKS - 1)));
}

sub is_valid_drivename {
    my $dev = shift;

    return defined($drivedesc_hash->{$dev}) && $dev !~ /^unused\d+$/;
}

PVE::JSONSchema::register_format('pve-qm-bootdisk', \&verify_bootdisk);

sub verify_bootdisk {
    my ($value, $noerr) = @_;

    return $value if is_valid_drivename($value);

    return if $noerr;

    die "invalid boot disk '$value'\n";
}

PVE::JSONSchema::register_format('pve-volume-id-or-qm-path', \&verify_volume_id_or_qm_path);

sub verify_volume_id_or_qm_path {
    my ($volid, $noerr) = @_;

    return $volid if $volid eq 'none' || $volid eq 'cdrom';

    return verify_volume_id_or_absolute_path($volid, $noerr);
}

PVE::JSONSchema::register_format(
    'pve-volume-id-or-absolute-path',
    \&verify_volume_id_or_absolute_path,
);

sub verify_volume_id_or_absolute_path {
    my ($volid, $noerr) = @_;

    return $volid if $volid =~ m|^/|;

    $volid = eval { PVE::JSONSchema::check_format('pve-volume-id', $volid, '') };
    if ($@) {
        return if $noerr;
        die $@;
    }
    return $volid;
}

# Tries to classify the drive file as either 'none', 'cdrom', 'absolute'
# or 'volume'. In all other cases it will return 'unknown'.
sub classify_drive_file {
    my ($volid) = @_;

    return 'unknown' if !$volid;

    if ($volid eq 'none') {
        return 'none';
    }

    if ($volid eq 'cdrom') {
        return 'cdrom';
    }

    if ($volid =~ m|^/|) {
        return 'absolute';
    }

    return PVE::Storage::parse_volume_id($volid, 1)
        ? 'volume'
        : 'unknown';
}

sub drive_is_cloudinit {
    my ($drive) = @_;
    return $drive->{file} =~ m@[:/](?:vm-\d+-)?cloudinit(?:\.$QEMU_FORMAT_RE)?$@;
}

sub drive_is_cdrom {
    my ($drive, $exclude_cloudinit) = @_;

    return 0 if $exclude_cloudinit && drive_is_cloudinit($drive);

    return $drive && $drive->{media} && ($drive->{media} eq 'cdrom');
}

# Whether the drive is an s390x DASD ('fba' or 'ckd').
sub drive_is_dasd {
    my ($drive) = @_;
    return $drive->{interface} eq 'fba' || $drive->{interface} eq 'ckd';
}

sub drive_has_absolute_path {
    my ($drive) = @_;
    return classify_drive_file($drive->{file}) eq "absolute";
}

# version ranges of the VirtIO driver ISO for Windows that are known to cause issues, see
# https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers#Known_Issues
my $virtio_win_issues = [
    { from => [0, 1, 215], to => [0, 1, 262] }, { from => [0, 1, 285], to => [0, 1, 285] },
];

# returns the version of the VirtIO driver ISO referenced by $volid if it is known to cause
# issues, undef otherwise
sub virtio_win_iso_issue {
    my ($volid) = @_;

    my @version = ($volid // '') =~ m/virtio-win[_-](\d+)\.(\d+)\.(\d+)/i;
    return if !@version;

    my $cmp_with = sub {
        my ($other) = @_;

        return PVE::Tools::version_cmp(map { ($version[$_], $other->[$_]) } 0 .. 2);
    };

    for my $issue ($virtio_win_issues->@*) {
        return join('.', @version)
            if $cmp_with->($issue->{from}) >= 0 && $cmp_with->($issue->{to}) <= 0;
    }

    return;
}

# warn if the CD-ROM drive $opt contains a VirtIO driver ISO that is known to cause issues
sub warn_about_virtio_win_issues {
    my ($opt, $volid) = @_;

    my $version = virtio_win_iso_issue($volid);
    return if !defined($version);

    log_warn("$opt: version $version of the VirtIO drivers for Windows is known to cause issues,"
        . " see https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers#Known_Issues");

    return;
}

# warn about every CD-ROM drive in $conf that contains a problematic VirtIO driver ISO
sub warn_about_virtio_win_issues_in_config {
    my ($conf) = @_;

    return if !PVE::QemuServer::Helpers::windows_version($conf->{ostype});

    for my $opt (valid_drive_names()) {
        next if !defined($conf->{$opt});

        my $drive = eval { parse_drive($opt, $conf->{$opt}) };
        next if !$drive || !drive_is_cdrom($drive, 1);

        warn_about_virtio_win_issues($opt, $drive->{file});
    }

    return;
}

sub parse_drive_interface {
    my ($key) = @_;

    if ($key =~ m/^([^\d]+)(\d+)$/) {
        return ($1, $2);
    }

    die "unable to parse drive interface $key\n";
}

# ideX = [volume=]volume-id[,media=d]
#        [,snapshot=on|off][,cache=on|off][,format=f][,backup=yes|no]
#        [,rerror=ignore|report|stop][,werror=enospc|ignore|report|stop]
#        [,aio=native|threads][,discard=ignore|on][,detect_zeroes=on|off]
#        [,iothread=on][,serial=serial][,model=model]

sub parse_drive {
    my ($key, $data, $with_alloc) = @_;

    my ($interface, $index) = eval { parse_drive_interface($key) };
    return if $@;

    my $desc_hash = $with_alloc ? $drivedesc_hash_with_alloc : $drivedesc_hash;

    if (!defined($desc_hash->{$key})) {
        warn "invalid drive key: $key\n";
        return;
    }

    my $desc = $desc_hash->{$key}->{format};
    my $res = eval {
        my $pps_opts = { skip => $DROPPED_PROPERTIES };
        PVE::JSONSchema::parse_property_string($desc, $data, undef, undef, $pps_opts);
    };
    return if !$res;
    $res->{interface} = $interface;
    $res->{index} = $index;

    my $error = 0;
    foreach my $opt (qw(bps bps_rd bps_wr)) {
        if (defined(my $bps = delete $res->{$opt})) {
            if (defined($res->{"m$opt"})) {
                warn "both $opt and m$opt specified\n";
                ++$error;
                next;
            }
            $res->{"m$opt"} = sprintf("%.3f", $bps / (1024 * 1024.0));
        }
    }

    # can't use the schema's 'requires' because of the mbps* => bps* "transforming aliases"
    for my $requirement (
        [mbps_max => 'mbps'],
        [mbps_rd_max => 'mbps_rd'],
        [mbps_wr_max => 'mbps_wr'],
        [miops_max => 'miops'],
        [miops_rd_max => 'miops_rd'],
        [miops_wr_max => 'miops_wr'],
        [bps_max_length => 'mbps_max'],
        [bps_rd_max_length => 'mbps_rd_max'],
        [bps_wr_max_length => 'mbps_wr_max'],
        [iops_max_length => 'iops_max'],
        [iops_rd_max_length => 'iops_rd_max'],
        [iops_wr_max_length => 'iops_wr_max'],
    ) {
        my ($option, $requires) = @$requirement;
        if ($res->{$option} && !$res->{$requires}) {
            warn "$option requires $requires\n";
            ++$error;
        }
    }

    return if $error;

    return if $res->{mbps_rd} && $res->{mbps};
    return if $res->{mbps_wr} && $res->{mbps};
    return if $res->{iops_rd} && $res->{iops};
    return if $res->{iops_wr} && $res->{iops};

    if ($res->{media} && ($res->{media} eq 'cdrom')) {
        return if $res->{snapshot} || $res->{format};
        return if $res->{interface} eq 'virtio';
    }

    if (my $size = $res->{size}) {
        return if !defined($res->{size} = PVE::JSONSchema::parse_size($size));
    }

    return $res;
}

sub print_drive {
    my ($drive, $with_alloc) = @_;
    my $skip = ['index', 'interface'];
    my $fmt = $with_alloc ? $alldrive_fmt_with_alloc : $alldrive_fmt;
    return PVE::JSONSchema::print_property_string($drive, $fmt, $skip);
}

sub get_drive_id {
    my ($drive) = @_;

    die "get_drive_id: no interface\n" if !defined($drive->{interface});
    die "get_drive_id: no index\n" if !defined($drive->{index});

    return "$drive->{interface}$drive->{index}";
}

sub get_bootdisks {
    my ($conf) = @_;

    my $bootcfg;
    $bootcfg = PVE::JSONSchema::parse_property_string('pve-qm-boot', $conf->{boot})
        if $conf->{boot};

    if (!defined($bootcfg) || $bootcfg->{legacy}) {
        return [$conf->{bootdisk}] if $conf->{bootdisk};
        return [];
    }

    my @list = PVE::Tools::split_list($bootcfg->{order});
    @list = grep { is_valid_drivename($_) } @list;
    return \@list;
}

sub bootdisk_size {
    my ($storecfg, $conf) = @_;

    my $bootdisks = get_bootdisks($conf);
    return if !@$bootdisks;
    for my $bootdisk (@$bootdisks) {
        next if !is_valid_drivename($bootdisk);
        next if !$conf->{$bootdisk};
        my $drive = parse_drive($bootdisk, $conf->{$bootdisk});
        next if !defined($drive);
        next if drive_is_cdrom($drive);
        my $volid = $drive->{file};
        next if !$volid;
        return $drive->{size};
    }

    return;
}

sub update_disksize {
    my ($drive, $newsize) = @_;

    return if !defined($newsize);

    my $oldsize = $drive->{size} // 0;

    if ($newsize != $oldsize) {
        $drive->{size} = $newsize;

        my $old_fmt = PVE::JSONSchema::format_size($oldsize);
        my $new_fmt = PVE::JSONSchema::format_size($newsize);

        my $msg = "size of disk '$drive->{file}' updated from $old_fmt to $new_fmt";

        return ($drive, $msg);
    }

    return;
}

sub is_volume_in_use {
    my ($storecfg, $conf, $skip_drive, $volid) = @_;

    my $path = PVE::Storage::path($storecfg, $volid);

    my $scan_config = sub {
        my ($cref) = @_;

        foreach my $key (keys %$cref) {
            my $value = $cref->{$key};
            if (is_valid_drivename($key)) {
                next if $skip_drive && $key eq $skip_drive;
                my $drive = parse_drive($key, $value);
                next if !$drive || !$drive->{file} || drive_is_cdrom($drive);
                return 1 if $volid eq $drive->{file};
                if ($drive->{file} =~ m!^/!) {
                    return 1 if $drive->{file} eq $path;
                } else {
                    my ($storeid, $volname) = PVE::Storage::parse_volume_id($drive->{file}, 1);
                    next if !$storeid;
                    my $scfg = PVE::Storage::storage_config($storecfg, $storeid, 1);
                    next if !$scfg;
                    return 1 if $path eq PVE::Storage::path($storecfg, $drive->{file});
                }
            }
        }

        return 0;
    };

    return 1 if &$scan_config($conf);

    undef $skip_drive;

    for my $snap (values %{ $conf->{snapshots} }) {
        return 1 if $scan_config->($snap);
    }

    return 0;
}

sub resolve_first_disk {
    my ($conf, $cdrom) = @_;
    my @disks = valid_drive_names_for_boot();
    foreach my $ds (@disks) {
        next if !$conf->{$ds};
        my $disk = parse_drive($ds, $conf->{$ds});
        next if drive_is_cdrom($disk) xor $cdrom;
        return $ds;
    }
    return;
}

sub scsi_inquiry {
    my ($fh, $noerr) = @_;

    my $SG_IO = 0x2285;
    my $SG_GET_VERSION_NUM = 0x2282;

    my $versionbuf = "\x00" x 8;
    my $ret = ioctl($fh, $SG_GET_VERSION_NUM, $versionbuf);
    if (!$ret) {
        die "scsi ioctl SG_GET_VERSION_NUM failoed - $!\n" if !$noerr;
        return;
    }
    my $version = unpack("I", $versionbuf);
    if ($version < 30000) {
        die "scsi generic interface too old\n" if !$noerr;
        return;
    }

    my $buf = "\x00" x 36;
    my $sensebuf = "\x00" x 8;
    my $cmd = pack("C x3 C x1", 0x12, 36);

    # see /usr/include/scsi/sg.h
    my $sg_io_hdr_t = "i i C C s I P P P I I i P C C C C S S i I I";

    my $packet = pack(
        $sg_io_hdr_t,
        ord('S'),
        -3,
        length($cmd),
        length($sensebuf),
        0,
        length($buf),
        $buf,
        $cmd,
        $sensebuf,
        6000,
    );

    $ret = ioctl($fh, $SG_IO, $packet);
    if (!$ret) {
        die "scsi ioctl SG_IO failed - $!\n" if !$noerr;
        return;
    }

    my @res = unpack($sg_io_hdr_t, $packet);
    if ($res[17] || $res[18]) {
        die "scsi ioctl SG_IO status error - $!\n" if !$noerr;
        return;
    }

    my $res = {};
    $res->@{qw(type removable vendor product revision)} = unpack("C C x6 A8 A16 A4", $buf);

    $res->{removable} = $res->{removable} & 128 ? 1 : 0;
    $res->{type} &= 0x1F;

    return $res;
}

sub path_is_scsi {
    my ($path) = @_;

    my $fh = IO::File->new("+<$path") || return;
    my $res = scsi_inquiry($fh, 1);
    close($fh);

    return $res;
}

sub get_scsi_device_type {
    my ($drive, $storecfg, $machine_version) = @_;

    my $devicetype = 'hd';
    my $path = '';
    if (drive_is_cdrom($drive) || drive_is_cloudinit($drive)) {
        $devicetype = 'cd';
    } else {
        if ($drive->{file} =~ m|^/|) {
            $path = $drive->{file};
            if (my $info = path_is_scsi($path)) {
                if ($info->{type} == 0 && $drive->{scsiblock}) {
                    $devicetype = 'block';
                } elsif ($info->{type} == 1) { # tape
                    $devicetype = 'generic';
                }
            }
        } elsif ($drive->{file} =~ $NEW_DISK_RE) {
            # special syntax cannot be parsed to path
            return $devicetype;
        } else {
            $path = PVE::Storage::path($storecfg, $drive->{file});
        }

        # for compatibility only, we prefer scsi-hd (#2408, #2355, #2380)
        if (
            $path =~ m/^iscsi\:\/\//
            && !PVE::QemuServer::Helpers::min_version($machine_version, 4, 1)
        ) {
            $devicetype = 'generic';
        }
    }

    return $devicetype;
}

sub storage_allows_io_uring_default {
    my ($scfg, $cache_direct) = @_;

    # io_uring with cache mode writeback or writethrough on krbd will hang...
    return if $scfg && $scfg->{type} eq 'rbd' && $scfg->{krbd} && !$cache_direct;

    # io_uring with cache mode writeback or writethrough on LVM will hang, without cache only
    # sometimes, just plain disable...
    return if $scfg && $scfg->{type} eq 'lvm';

    # io_uring causes problems when used with CIFS since kernel 5.15
    # Some discussion: https://www.spinics.net/lists/linux-cifs/msg26734.html
    return if $scfg && $scfg->{type} eq 'cifs';

    return 1;
}

sub drive_uses_cache_direct {
    my ($drive, $scfg) = @_;

    my $cache_direct = 0;

    if (my $cache = $drive->{cache}) {
        $cache_direct = $cache =~ /^(?:off|none|directsync)$/;
    } elsif (!drive_is_cdrom($drive) && !($scfg && $scfg->{type} eq 'btrfs' && !$scfg->{nocow})) {
        $cache_direct = 1;
    }

    return $cache_direct;
}

sub aio_cmdline_option {
    my ($scfg, $drive, $cache_direct) = @_;

    return $drive->{aio} if $drive->{aio};

    if (storage_allows_io_uring_default($scfg, $cache_direct)) {
        # io_uring supports all cache modes
        return 'io_uring';
    } else {
        # aio native works only with O_DIRECT
        if ($cache_direct) {
            return 'native';
        } else {
            return 'threads';
        }
    }
}

# must not be called for CD-ROMs
sub detect_zeroes_cmdline_option {
    my ($drive) = @_;

    die "cannot use detect-zeroes for CD-ROM\n" if drive_is_cdrom($drive);

    if (defined($drive->{detect_zeroes}) && !$drive->{detect_zeroes}) {
        return 'off';
    } elsif ($drive->{discard}) {
        return $drive->{discard} eq 'on' ? 'unmap' : 'on';
    }

    # This used to be our default with discard not being specified:
    return 'on';
}

sub drive_uses_qsd_fuse {
    my ($storecfg, $drive) = @_;

    if ($drive->{interface} eq 'tpmstate') {
        my ($storeid) = PVE::Storage::parse_volume_id($drive->{file}, 1);
        return if !$storeid; # not managed by the PVE storage layer

        # The iSCSIDirect and ZFS-over-iSCSI plugins do not implement map_volume() and only provide
        # an iscsi protocol path. Use QSD to make such volumes accessible to swtpm.
        my $path = PVE::Storage::path($storecfg, $drive->{file});
        return 1 if $path =~ m!^iscsi://!;

        my $format = checked_volume_format($storecfg, $drive->{file});
        return $format ne 'raw';
    }

    return;
}

sub drive_qmp_peer {
    my ($storecfg, $vmid, $drive) = @_;

    return drive_uses_qsd_fuse($storecfg, $drive) ? qsd_qmp_peer($vmid) : vm_qmp_peer($vmid);
}

# Takes a VM config and the storage configuration. Parses the configuration,
# checks the drive size and updates it to the maximum between the actual size
# and the static TPMSTATE_DISK_SIZE which is 4MiB.
sub update_tpmstate_size {
    my ($conf, $storecfg) = @_;

    die "a configuration has to be supplied in which to update the tpm state size"
        if !defined($conf);

    die "the storage config has to be supplied to determine tpm state size"
        if !defined($storecfg);

    return if !defined($conf->{tpmstate0});

    my $disk = parse_drive('tpmstate0', $conf->{tpmstate0});

    $disk->{size} = get_tpmstate_size($disk->{file}, $storecfg);
    $conf->{tpmstate0} = print_drive($disk);
}

# Takes in a volume id and the storage configuration. Will then try to find
# the actual storage size of the TPM drive. The final value has a minimum
# determined by the TPMSTATE_DISK_SIZE static, which is 4MiB.
sub get_tpmstate_size {
    my ($volid, $storecfg) = @_;

    die "a volume id has to be supplied to determine tpm state size"
        if !defined($volid);

    die "the storage config has to be supplied to determine tpm state size"
        if !defined($storecfg);

    my $size = eval { PVE::Storage::volume_size_info($storecfg, $volid, 10) };
    warn "failed to get size of the tpm drive $volid: $@" if $@;

    if (!$size || $size < TPMSTATE_DISK_SIZE) {
        $size = TPMSTATE_DISK_SIZE;
    }

    return $size;
}

1;
