package PVE::QemuServer::DASD;

# DASDs of s390x VMs: FBA disks (fba-ccw, an IBM 9336 with 512-byte blocks, the plain volume
# content) and CKD disks (eckd-ccw, an IBM 3390).
#
# A CKD volume holds an uncompressed Hercules CKD image: a 512-byte device header followed by one
# 56832-byte slot per track, 15 tracks per cylinder. The header says how many cylinders the
# volume has (the one-origin 'high_cylinder' field), the storage volume may be larger, the rest
# is never accessed. A track slot that is all zero reads as an empty, initialized track, so a new
# volume is just the header on a (sparse) volume of sufficient size; the guest formats it, with
# ICKDSF or dasdfmt for example. The volume serial (VOLSER) is written by the guest, not here.

use strict;
use warnings;

use File::Temp;

use PVE::Storage;
use PVE::QemuServer::Helpers;
use PVE::Tools qw(run_command);

use constant {
    CKD_HEADER_SIZE => 512,
    CKD_TRACK_SIZE => 56832,
    CKD_HEADS => 15,
    CKD_MAX_CYLINDERS => 65520,
    CKD_DEVICE_TYPE => 0x90, # 3390
    FBA_BLOCK_SIZE => 512,
    FBA_MAX_SIZE => 512 * 2**32, # 32-bit block numbers
};

# Cylinders of the 3390 models. Larger volumes (3390-A, extended address volumes beyond 65520
# cylinders) are not supported by the 16-bit cylinder count of the CKD image header.
my $ckd_models = {
    '3390-1' => 1113,
    '3390-2' => 2226,
    '3390-3' => 3339,
    '3390-9' => 10017,
    '3390-27' => 32760,
    '3390-54' => 65520,
};

sub ckd_models {
    return {%$ckd_models};
}

sub ckd_cylinder_size {
    return CKD_HEADS * CKD_TRACK_SIZE;
}

# The bytes a CKD volume of $cylinders cylinders needs.
sub ckd_volume_size {
    my ($cylinders) = @_;
    return CKD_HEADER_SIZE + $cylinders * ckd_cylinder_size();
}

# The cylinders of a new CKD volume as given in the drive: 'cylinders' or 'model'.
sub ckd_cylinders_of_drive {
    my ($drive) = @_;

    my ($model, $cylinders) = $drive->@{qw(model cylinders)};
    if (defined($model) && $model ne '3390') { # '3390': a cylinder count of no standard model
        my $model_cylinders = $ckd_models->{$model} or die "unknown CKD model '$model'\n";
        die "'cylinders' $cylinders does not match model $model ($model_cylinders cylinders)\n"
            if defined($cylinders) && $cylinders != $model_cylinders;
        $cylinders = $model_cylinders;
    }
    die "need 'model' or 'cylinders' to create a CKD volume\n" if !defined($cylinders);
    die "a CKD volume has 1 to " . CKD_MAX_CYLINDERS . " cylinders\n"
        if $cylinders < 1 || $cylinders > CKD_MAX_CYLINDERS;

    return $cylinders;
}

# The 3390 model of a CKD volume with $cylinders cylinders: '3390-<n>' for the standard sizes,
# '3390' for others.
sub ckd_model_of_cylinders {
    my ($cylinders) = @_;

    return '3390' if !defined($cylinders);
    for my $model (sort keys %$ckd_models) {
        return $model if $ckd_models->{$model} == $cylinders;
    }
    return '3390';
}

# The 'model' of a DASD drive, stored in the configuration when the volume is created, imported or
# attached: the 3390 model of a CKD volume (by its cylinders), '9336' for an FBA volume. A given
# model must match the cylinders. Not for the cloud-init drive.
sub set_drive_model {
    my ($key, $drive) = @_;

    if ($drive->{interface} eq 'ckd') {
        my ($model, $cylinders) = $drive->@{qw(model cylinders)};
        if (!defined($model)) {
            $drive->{model} = ckd_model_of_cylinders($cylinders) if defined($cylinders);
        } elsif (defined($cylinders) && defined(my $model_cylinders = $ckd_models->{$model})) {
            die "$key: a $model has $model_cylinders cylinders, the volume has $cylinders\n"
                if $model_cylinders != $cylinders;
        }
    } elsif ($drive->{interface} eq 'fba') {
        $drive->{model} //= '9336';
    }
    return;
}

# The 512-byte header of a CKD volume. $serial is the 12-character device serial QEMU reports in
# the configuration data of the device (like Hercules, decimal digits); random if not given.
sub ckd_header {
    my ($cylinders, $serial, $identifier) = @_;

    $identifier //= 'CKD_P064';
    $serial //= join('', map { int(rand(10)) } 1 .. 12);

    my $header = pack(
        'a8 V V C C v a12',
        $identifier, CKD_HEADS, CKD_TRACK_SIZE, CKD_DEVICE_TYPE, 0, $cylinders, $serial,
    );
    return $header . ("\0" x (CKD_HEADER_SIZE - length($header)));
}

# Parse a CKD image header. $length is the size of the image (volume) in bytes. Returns
# { identifier, cylinders, serial, 'high-cylinder' } or dies with what is wrong.
sub parse_ckd_header {
    my ($data, $length) = @_;

    die "not a CKD image: shorter than its header\n"
        if length($data) < CKD_HEADER_SIZE || $length < CKD_HEADER_SIZE;

    my ($identifier, $heads, $track_size, $device_type, $file_sequence, $high_cylinder, $serial) =
        unpack('a8 V V C C v a12', $data);

    if ($identifier =~ m/^CKD_[CS](370|064)$/) {
        die "compressed (CCKD) or shadow CKD images are not supported, convert it to an"
            . " uncompressed CKD image first, for example with Hercules"
            . " 'dasdcopy -o CKD <in> <out>' (or cckd2ckd/cckd642ckd)\n";
    }
    if ($identifier =~ m/^FBA_[CS](370|064)$/) {
        die "this is a compressed FBA image (CFBA), not a CKD image\n";
    }
    die "not a CKD image: no CKD_P370 or CKD_P064 header\n"
        if $identifier ne 'CKD_P370' && $identifier ne 'CKD_P064';
    die sprintf(
        "unsupported CKD image: device type %02x with %d heads and %d-byte tracks, only 3390"
            . " volumes (15 heads, 56832-byte tracks) are supported\n",
        $device_type,
        $heads,
        $track_size,
        )
        if $device_type != CKD_DEVICE_TYPE || $heads != CKD_HEADS || $track_size != CKD_TRACK_SIZE;

    my $data_length = $length - CKD_HEADER_SIZE;
    my $cylinders;
    if (!$file_sequence && $high_cylinder) {
        $cylinders = $high_cylinder;
        die "CKD image is too short for $cylinders cylinders\n"
            if $data_length < $cylinders * ckd_cylinder_size();
    } else {
        die "CKD image does not contain whole cylinders\n"
            if $data_length % ckd_cylinder_size();
        $cylinders = $data_length / ckd_cylinder_size();
        die "multi-file CKD images are not supported, join them first, for example with"
            . " Hercules 'dasdcopy -lfs'\n"
            if ($file_sequence || $high_cylinder) && $high_cylinder != $cylinders;
    }
    die "CKD image has $cylinders cylinders, supported are 1 to " . CKD_MAX_CYLINDERS . "\n"
        if $cylinders < 1 || $cylinders > CKD_MAX_CYLINDERS;

    return {
        identifier => $identifier,
        cylinders => $cylinders,
        serial => $serial,
        'high-cylinder' => $high_cylinder,
    };
}

# Read the first 512 bytes of an image with qemu-img (any format and protocol). $force_share for
# an image a running VM has open.
sub read_image_head {
    my ($path, $format, $force_share) = @_;

    my $dir = File::Temp->newdir('/tmp/pve-dasd-XXXXXX');
    my $out = "$dir/head";
    run_command(
        [
            '/usr/bin/qemu-img',
            'dd',
            ($force_share ? '-U' : ()),
            '-f',
            $format,
            '-O',
            'raw',
            'bs=512',
            'count=1',
            "if=$path",
            "of=$out",
        ],
        errmsg => "unable to read the header of '$path'",
    );
    return PVE::Tools::file_get_contents($out);
}

# Write a 512-byte header to the start of an image with qemu-io.
sub write_image_head {
    my ($path, $format, $data) = @_;

    die "internal error: header must be 512 bytes\n" if length($data) != CKD_HEADER_SIZE;

    my $dir = File::Temp->newdir('/tmp/pve-dasd-XXXXXX');
    my $in = "$dir/head";
    PVE::Tools::file_set_contents($in, $data);
    run_command(
        ['/usr/bin/qemu-io', '-f', $format, '-c', "write -s $in 0 512", $path],
        outfunc => sub { },
        errmsg => "unable to write the CKD header to '$path'",
    );
}

my sub volume_path_and_format {
    my ($storecfg, $volid) = @_;

    PVE::Storage::activate_volumes($storecfg, [$volid]);
    my $path = PVE::Storage::path($storecfg, $volid);
    my $format = (PVE::Storage::parse_volname($storecfg, $volid))[6] // 'raw';
    my $size = PVE::Storage::volume_size_info($storecfg, $volid);
    die "could not get the size of '$volid'\n" if !$size;
    return ($path, $format, $size);
}

# The bytes to allocate for a CKD volume, in KiB as vdisk_alloc expects them.
sub ckd_alloc_size_kib {
    my ($cylinders) = @_;
    my $bytes = ckd_volume_size($cylinders);
    return int(($bytes + 1023) / 1024);
}

# Write the header of a new CKD volume.
sub init_ckd_volume {
    my ($storecfg, $volid, $cylinders) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    die "volume '$volid' is too small for $cylinders cylinders\n"
        if $size < ckd_volume_size($cylinders);
    write_image_head($path, $format, ckd_header($cylinders));
}

# Check the CKD header of an existing volume. If the header leaves the size to the length of the
# image (Hercules does), write the cylinder count into it, so the volume stays usable when its
# storage rounds up the size (move, restore, clone). Returns the parsed header.
sub check_ckd_volume {
    my ($storecfg, $volid) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $data = read_image_head($path, $format);
    my $header = eval { parse_ckd_header($data, $size) };
    die "volume '$volid': $@" if $@;

    if ($header->{'high-cylinder'} != $header->{cylinders}) {
        print "volume '$volid': setting the cylinder count in the CKD header\n";
        write_image_head(
            $path,
            $format,
            ckd_header($header->{cylinders}, $header->{serial}, $header->{identifier}),
        );
        $header->{'high-cylinder'} = $header->{cylinders};
    }

    return $header;
}

# The header of the CKD volume of a running VM, for its migration target (see
# init_ckd_volume_from_header()), with the cylinder count in it: the target volume may be larger.
sub ckd_volume_header_for_migration {
    my ($storecfg, $volid) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $data = read_image_head($path, $format, 1);
    my $header = eval { parse_ckd_header($data, $size) };
    die "volume '$volid': $@" if $@;

    return substr($data, 0, CKD_HEADER_SIZE) if $header->{'high-cylinder'} == $header->{cylinders};
    return ckd_header($header->{cylinders}, $header->{serial}, $header->{identifier});
}

# Write the header of the CKD volume of a migrating VM (see ckd_volume_header_for_migration())
# into its new, empty volume on the target. The eckd-ccw device of the target needs it to start,
# the storage migration then copies the whole volume, the same header included. Returns the
# parsed header.
sub init_ckd_volume_from_header {
    my ($storecfg, $volid, $data) = @_;

    die "internal error: CKD header must be " . CKD_HEADER_SIZE . " bytes\n"
        if length($data) != CKD_HEADER_SIZE;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $header = eval { parse_ckd_header($data, $size) };
    die "volume '$volid': $@" if $@;
    die "volume '$volid': the CKD header has no cylinder count\n"
        if $header->{'high-cylinder'} != $header->{cylinders};
    write_image_head($path, $format, $data);

    return $header;
}

# Complete a CKD volume imported from an image whose header ($source_header, see
# check_ckd_import_source()) was checked before: write the cylinder count of the source into the
# header of the volume, as the storage may have made it larger (LVM extents, ZFS volblocksize) and
# the slack must not count as cylinders. Returns the header of the volume.
sub finish_ckd_import {
    my ($storecfg, $volid, $source_header) = @_;

    return check_ckd_volume($storecfg, $volid) if !$source_header;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $cylinders = $source_header->{cylinders};
    die "volume '$volid' is too small for $cylinders cylinders\n"
        if $size < ckd_volume_size($cylinders);

    my $header = { $source_header->%*, 'high-cylinder' => $cylinders };
    if ($source_header->{'high-cylinder'} != $cylinders) {
        print "volume '$volid': setting the cylinder count in the CKD header\n";
        write_image_head(
            $path, $format, ckd_header($cylinders, $header->{serial}, $header->{identifier}),
        );
    }

    return $header;
}

# Check an image to be imported as a CKD volume, before importing it. Returns the parsed header.
sub check_ckd_import_source {
    my ($path, $format, $size) = @_;

    my $data = read_image_head($path, $format);
    my $header = eval { parse_ckd_header($data, $size) };
    die "cannot import '$path' as CKD volume: $@" if $@;
    return $header;
}

# Check an image to be imported as an FBA volume.
sub check_fba_import_source {
    my ($path, $format, $size) = @_;

    die "cannot import '$path' as FBA volume: its size is not a multiple of 512 bytes\n"
        if $size % FBA_BLOCK_SIZE;
    check_fba_size($size);

    my $data = read_image_head($path, $format);
    my $identifier = substr($data, 0, 8);
    die "cannot import '$path' as FBA volume: compressed FBA (CFBA) images are not"
        . " supported, convert it first, for example with Hercules 'dasdcopy -o FBA <in> <out>'"
        . " (or cfba2fba)\n"
        if $identifier =~ m/^FBA_[CS](370|064)$/;
    die "cannot import '$path' as FBA volume: it is a CKD image\n"
        if $identifier =~ m/^CKD_[PCS](370|064)$/;
}

sub check_fba_size {
    my ($size) = @_;
    die "an FBA volume can have at most 2 TiB (2^32 blocks of 512 bytes)\n"
        if $size > FBA_MAX_SIZE;
}

# The volume name for a new DASD volume with a user given name, as vdisk_alloc() expects it, or
# undef to let the storage choose one.
sub dasd_volume_name {
    my ($storecfg, $storeid, $vmid, $fmt, $name) = @_;

    return if !defined($name) || $name eq '';

    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
    my $volname = "vm-$vmid-$name";
    if ($scfg->{path} || ($scfg->{'snapshot-as-volume-chain'} && $fmt eq 'qcow2')) {
        $volname .= ".$fmt";
    }
    return $volname;
}

# The QEMU device properties of the identity override of a DASD (drive options 'devtype' and
# 'cutype', type and optional model in hex), as a string to append to the device. They need a QEMU
# build whose eckd-ccw and fba-ccw devices have the properties (named like those of the 3270
# device of QEMU-mod).
# TODO: confirm the property names once QEMU-mod has them for the DASD devices.
my $identity_properties = {
    devtype => ['device-type', 'device-model'],
    cutype => ['control-unit-type', 'control-unit-model'],
};

sub identity_properties {
    my ($drive_id, $drive, $arch) = @_;

    my $res = '';
    my $device = $drive->{interface} eq 'fba' ? 'fba-ccw' : 'eckd-ccw';
    for my $opt (sort keys %$identity_properties) {
        next if !defined($drive->{$opt});
        my ($type_prop, $model_prop) = $identity_properties->{$opt}->@*;
        my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
        die "$drive_id: '$opt' needs a QEMU with the '$type_prop' property of the $device device,"
            . " the installed one does not have it\n"
            if !PVE::QemuServer::Helpers::kvm_device_has_property($binary, $device, $type_prop);
        my ($type, $model) = $drive->{$opt} =~ m/^([0-9a-f]{4})(?:-([0-9a-f]{2}))?$/i
            or die "$drive_id: invalid $opt '$drive->{$opt}'\n";
        $res .= ",$type_prop=" . hex($type);
        $res .= ",$model_prop=" . hex($model) if defined($model);
    }
    return $res;
}

my $volume_name_re = qr/[A-Za-z0-9][A-Za-z0-9_-]{0,39}/;

# The user given name of the volume of a volume ID 'vm-<vmid>-<name>' (of any VM, the source of a
# restore or an import may be another one), without the file extension of the storage. For example
# the VOLSER 'SYSRS1' of 'local-lvm:vm-300-SYSRS1'. Undef for a name the storage chose
# ('disk-<n>', 'cloudinit') and for other volumes. Only looks at the string: the storage of a
# backed up volume may not exist here.
sub volume_name_of_volid {
    my ($volid) = @_;

    return if !defined($volid);
    my ($name) = $volid =~ m!(?:^|[:/])vm-\d+-($volume_name_re)(?:\.(?:raw|qcow2|vmdk))?$! or return;
    return if $name =~ m/^disk-\d+$/ || $name eq 'cloudinit';
    return $name;
}

# The name for a DASD volume imported from $source (a volume ID or an absolute path): the name of
# a volume 'vm-<vmid>-<name>', or of a Hercules DASD image file (like 'SYSRS1.ckd'). Undef for
# other sources: the members of an OVA carry their name as drive option 'name'.
sub import_source_volume_name {
    my ($source) = @_;

    return if !defined($source);
    if ($source =~ m!(?:^/|^[^/:]+:import/)(?:[^/]*/)*($volume_name_re)\.(?:ckd|ckd64|fba)$!i) {
        return $1;
    }
    return if $source =~ m!\.ova/!;
    return volume_name_of_volid($source);
}

# Allocate a volume called 'vm-<vmid>-<name>' (see dasd_volume_name()), or, if that is not
# possible (the name is taken on the storage), one with a name the storage chooses, with a warning.
# For the volumes of imported and restored DASDs, which keep the names of their source volumes.
# $what names the drive in the warning. Returns the volume ID.
sub alloc_named_volume {
    my ($storecfg, $storeid, $vmid, $fmt, $name, $size_kib, $what) = @_;

    if (defined($name) && $name ne '') {
        my $volname = dasd_volume_name($storecfg, $storeid, $vmid, $fmt, $name);
        my $volid =
            eval { PVE::Storage::vdisk_alloc($storecfg, $storeid, $vmid, $fmt, $volname, $size_kib) };
        return $volid if defined($volid);
        my $err = $@ // '';
        chomp($err);
        warn "warning: $what: unable to allocate the volume '$volname' on storage '$storeid'"
            . " ($err), using the default volume name\n";
    }
    return PVE::Storage::vdisk_alloc($storecfg, $storeid, $vmid, $fmt, undef, $size_kib);
}

1;
