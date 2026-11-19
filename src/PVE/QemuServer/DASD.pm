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
    if (defined($model)) {
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

# Resize a CKD volume of a VM that is not running: grow it by whole cylinders, to at most
# $newsize bytes, or by at most $increment bytes if given (the volume may be larger than its
# cylinders need, so that is not the same), and write the new cylinder count into the header.
# Returns the new size of the volume in bytes and the new cylinder count.
sub resize_ckd_volume {
    my ($storecfg, $volid, $newsize, $increment) = @_;

    my $header = check_ckd_volume($storecfg, $volid);
    my $cylinders =
        defined($increment)
        ? $header->{cylinders} + int($increment / ckd_cylinder_size())
        : int(($newsize - CKD_HEADER_SIZE) / ckd_cylinder_size());
    $cylinders = CKD_MAX_CYLINDERS if $cylinders > CKD_MAX_CYLINDERS;
    die "a CKD volume grows by whole cylinders of "
        . ckd_cylinder_size()
        . " bytes, up to "
        . CKD_MAX_CYLINDERS
        . " cylinders: no room to grow the $header->{cylinders} cylinders of '$volid'\n"
        if $cylinders <= $header->{cylinders};

    my $size = PVE::Storage::volume_size_info($storecfg, $volid);
    my $needed = ckd_volume_size($cylinders);
    if ($needed > $size) {
        PVE::Storage::volume_resize($storecfg, $volid, $needed, 0); # rounds up to whole KiB
        $size = PVE::Storage::volume_size_info($storecfg, $volid);
    }

    my ($path, $format) = volume_path_and_format($storecfg, $volid);
    write_image_head(
        $path,
        $format,
        ckd_header($cylinders, $header->{serial}, $header->{identifier}),
    );

    return ($size, $cylinders);
}

1;
