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
use PVE::QemuServer::Drive;
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
    my ($cylinders, $serial, $identifier, $file_sequence) = @_;

    $identifier //= 'CKD_P064';
    $serial //= join('', map { int(rand(10)) } 1 .. 12);

    my $header = pack(
        'a8 V V C C v a12',
        $identifier,
        CKD_HEADS,
        CKD_TRACK_SIZE,
        CKD_DEVICE_TYPE,
        $file_sequence // 0,
        $cylinders,
        $serial,
    );
    return $header . ("\0" x (CKD_HEADER_SIZE - length($header)));
}

# The first pve-qemu-kvm whose QEMU-mod accepts a CKD image longer than the cylinder count of its
# header whatever its file sequence (the header is the authority, the rest is slack it ignores; a
# shorter image is still an error), see ckd_image_needs_exact_size().
our $CKD_SLACK_PVE_QEMU_VERSION = '11.1.90-1+s390x10';

my $ckd_slack_cache = {};

# Whether the installed QEMU accepts slack after the cylinders of any CKD image, by the version of
# pve-qemu-kvm (rechecked when the QEMU binary changes).
sub ckd_slack_supported {
    my $binary = '/usr/bin/qemu-system-s390x';
    my $mtime = (stat($binary))[9] // -1;
    return $ckd_slack_cache->{supported} if ($ckd_slack_cache->{mtime} // -2) == $mtime;

    my $version = '';
    eval {
        run_command(
            ['/usr/bin/dpkg-query', '-W', '-f=${Version}', 'pve-qemu-kvm'],
            outfunc => sub { $version .= shift },
            errfunc => sub { },
        );
    };
    my $supported = 0;
    if ($version ne '') {
        my $res = eval {
            run_command(
                ['/usr/bin/dpkg', '--compare-versions', $version, 'ge', $CKD_SLACK_PVE_QEMU_VERSION],
                noerr => 1,
                quiet => 1,
            );
        };
        $supported = defined($res) && $res == 0 ? 1 : 0;
    }
    $ckd_slack_cache = { mtime => $mtime, supported => $supported };
    return $supported;
}

# Whether the volume of a CKD image must be exactly as large as the cylinders of the image, without
# slack after the last cylinder. The eckd-ccw device of QEMU-mod up to pve-qemu-kvm
# 11.1.90-1+s390x9 takes the cylinder count from the header ('high_cylinder', one-origin) and
# ignores slack only if the 'file_sequence' of the header is 0 (Hercules). Images from zPDT have
# another file sequence (0x04) and a cylinder count: that QEMU-mod takes their size from the length
# of the image, which must then be a whole number of cylinders. Storages that round sizes up (ZFS
# volblocksize, LVM extents) cannot hold them, file based storages can (see
# storage_has_exact_size(), fit_ckd_volume()). Later builds accept the slack (see
# ckd_slack_supported()).
#
# This is the one place that decides it: parse_ckd_header() accepts the slack if not,
# assert_ckd_target_storage() refuses storages that round up if so, fit_ckd_volume() cuts slack on
# file based storages either way.
sub ckd_image_needs_exact_size {
    my ($header) = @_;
    return $header->{'file-sequence'} && !ckd_slack_supported() ? 1 : 0;
}

# Parse a CKD image header. $length is the size of the image (volume) in bytes. Returns
# { identifier, cylinders, serial, 'high-cylinder', 'file-sequence' } or dies with what is wrong.
# With $allow_slack, an image that has a cylinder count and another file sequence than 0 (zPDT) may
# be longer than its cylinders, as when it was copied to a storage that rounds up the size: for the
# source of a copy, whose slack fit_ckd_volume() removes, and for volumes that need fixing.
sub parse_ckd_header {
    my ($data, $length, $allow_slack) = @_;

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
    my $slack_ok = !$file_sequence
        || $allow_slack
        || !ckd_image_needs_exact_size({ 'file-sequence' => $file_sequence });
    if ($high_cylinder && $file_sequence && $slack_ok) {
        # A member of a multi-file Hercules volume has a zero-origin high cylinder: its length is
        # whole cylinders beyond it, never the slack of a storage.
        my $slack = $data_length - $high_cylinder * ckd_cylinder_size();
        $slack_ok = 0 if $slack > 0 && $slack % ckd_cylinder_size() == 0;
    }
    my $cylinders;
    if ($high_cylinder && $slack_ok) {
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
        'file-sequence' => $file_sequence,
    };
}

my $ebcdic_volser_chars = {
    (map { (0xc1 + $_ => chr(ord('A') + $_)) } 0 .. 8),
    (map { (0xd1 + $_ => chr(ord('J') + $_)) } 0 .. 8),
    (map { (0xe2 + $_ => chr(ord('S') + $_)) } 0 .. 7),
    (map { (0xf0 + $_ => chr(ord('0') + $_)) } 0 .. 9),
    0x40 => ' ',
};

# The volume serial (VOLSER) of a CKD image from its first track ($data: the image from its start,
# header included, at least up to the volume label), or undef. The standard volume label of the
# mainframe operating systems and Linux on the compatible disk layout is record 3 of cylinder 0, head 0: key 'VOL1',
# data 'VOL1' followed by the six characters of the VOLSER, in EBCDIC. Only VOLSERs of letters and
# digits, which can name a volume (see dasd_volume_name()), the national characters (@, #, $) not.
sub ckd_volser {
    my ($data) = @_;

    my $pos = CKD_HEADER_SIZE + 5; # the home address of the track: flag, cylinder, head
    my $vol1 = "\xe5\xd6\xd3\xf1"; # 'VOL1'
    for (1 .. 8) { # record 0 (no key), 1 and 2 (IPL records), 3
        return if length($data) < $pos + 8;
        my ($cc, $hh, $record, $key_length, $data_length) =
            unpack('n n C C n', substr($data, $pos, 8));
        return if $cc == 0xffff || $cc != 0 || $hh != 0; # end of track
        $pos += 8;
        if ($record == 3) {
            return if $key_length != 4 || $data_length < 10;
            return if length($data) < $pos + 4 + 10;
            return if substr($data, $pos, 4) ne $vol1 || substr($data, $pos + 4, 4) ne $vol1;
            my $volser = '';
            for my $byte (unpack('C6', substr($data, $pos + 8, 6))) {
                my $char = $ebcdic_volser_chars->{$byte} // return;
                $volser .= $char;
            }
            $volser =~ s/ +$//;
            return $volser =~ m/^[A-Z0-9]+$/ ? $volser : undef;
        }
        $pos += $key_length + $data_length;
    }
    return;
}

# Read the first 512 bytes (or $blocks 512-byte blocks) of an image with qemu-img (any format and
# protocol). $force_share for an image a running VM has open.
sub read_image_head {
    my ($path, $format, $force_share, $blocks) = @_;

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
            'count=' . ($blocks // 1),
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

# Whether a volume of storage $storeid in format $format can have any size in bytes, exactly that of
# a CKD image: files (raw, qcow2) of file based storages, which fit_ckd_volume() can cut. Block
# storages round the size up (ZFS volblocksize, LVM extents, Ceph RBD), as do volume chains.
sub storage_has_exact_size {
    my ($storecfg, $storeid, $format) = @_;

    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
    return 0 if !$scfg->{path} || $scfg->{'snapshot-as-volume-chain'};
    return ($format // '') =~ m/^(?:raw|qcow2)$/ ? 1 : 0;
}

# Refuse to put a CKD image ($header, see parse_ckd_header()) on storage $storeid in format
# $format if QEMU could not use it there (see ckd_image_needs_exact_size()). Before anything is
# allocated or copied. $what names the drive in the message.
sub assert_ckd_target_storage {
    my ($storecfg, $storeid, $format, $header, $what) = @_;

    return if !ckd_image_needs_exact_size($header);
    return if storage_has_exact_size($storecfg, $storeid, $format);

    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
    die sprintf(
        "%s: the CKD image needs a volume of exactly %d bytes (%d cylinders, its header has"
            . " file sequence 0x%02x like images from zPDT): storage '%s' (%s%s) rounds the size"
            . " up and QEMU would refuse the volume. Use a file based storage (like a directory"
            . " or NFS storage) with format raw or qcow2.\n",
        $what,
        ckd_volume_size($header->{cylinders}),
        $header->{cylinders},
        $header->{'file-sequence'},
        $storeid,
        $scfg->{type},
        ($scfg->{path} ? ", format " . ($format // 'raw') : ''),
    );
}

# Make the volume of a copied CKD image what QEMU accepts: cut slack after its cylinders (from the
# source, or the storage rounding up the size) on file based storages, refuse a volume with slack
# that QEMU would not accept elsewhere. The header of the volume must have the cylinder count of
# $header (see finish_ckd_import()): without it, the length of the image is the count. Returns the
# size of the volume.
sub fit_ckd_volume {
    my ($storecfg, $volid, $header) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $cylinders = $header->{cylinders};
    my $exact = ckd_volume_size($cylinders);
    die "volume '$volid' is too small for $cylinders cylinders\n" if $size < $exact;
    return $size if $size == $exact;

    my ($storeid) = PVE::Storage::parse_volume_id($volid);
    if (storage_has_exact_size($storecfg, $storeid, $format)) {
        print "volume '$volid': cutting the slack after the $cylinders cylinders of the CKD image"
            . " ($size to $exact bytes)\n";
        run_command(
            ['/usr/bin/qemu-img', 'resize', '--shrink', '-f', $format, $path, $exact],
            outfunc => sub { },
            errmsg => "unable to cut '$path' to $exact bytes",
        );
        return $exact;
    }
    assert_ckd_target_storage($storecfg, $storeid, $format, $header, "volume '$volid'");
    return $size;
}

# Complete and fit (see fit_ckd_volume()) the CKD volume $volid that was just copied or restored
# with its own header: write the cylinder count into the header if it has none. Returns the header.
sub fit_copied_ckd_volume {
    my ($storecfg, $volid, $source_header) = @_;

    my $header = $source_header;
    if (!$header) {
        my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
        $header = eval { parse_ckd_header(read_image_head($path, $format), $size, 1) };
        die "volume '$volid': $@" if $@;
    }
    $header = finish_ckd_import($storecfg, $volid, $header);
    return $header;
}

# The qemu-img --image-opts of the first $size bytes of the image $path in format $format, for
# copying a CKD image without slack after its cylinders.
sub image_opts_cut {
    my ($path, $format, $size) = @_;

    die "cannot cut '$path': not a local file or block device\n" if $path !~ m!^/!;
    die "cannot cut '$path': unsupported format '$format'\n" if $format !~ m/^(?:raw|qcow2|vmdk)$/;
    die "cannot cut '$path': ',' in the path\n" if $path =~ m/,/;
    my $protocol = -b $path ? 'host_device' : 'file';
    my $file = $format eq 'raw'
        ? "file.driver=$protocol,file.filename=$path"
        : "file.driver=$format,file.file.driver=$protocol,file.file.filename=$path";
    return "driver=raw,offset=0,size=$size,$file";
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
# With $dry_run, only check.
sub check_ckd_volume {
    my ($storecfg, $volid, $dry_run) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $data = read_image_head($path, $format);
    my $header = eval { parse_ckd_header($data, $size) };
    if (my $err = $@) {
        # a zPDT image with slack: say what to do about it
        if (my $slack_header = eval { parse_ckd_header($data, $size, 1) }) {
            chomp($err);
            die "volume '$volid': $err - the CKD image needs a volume of exactly "
                . ckd_volume_size($slack_header->{cylinders})
                . " bytes, not $size (its header has file sequence"
                . sprintf(" 0x%02x", $slack_header->{'file-sequence'})
                . "), move it to a file based storage (like a directory or NFS storage) with"
                . " format raw or qcow2, which cuts the slack\n";
        }
        die "volume '$volid': $err";
    }

    if (!$dry_run && $header->{'high-cylinder'} != $header->{cylinders}) {
        print "volume '$volid': setting the cylinder count in the CKD header\n";
        write_image_head(
            $path,
            $format,
            ckd_header(
                $header->{cylinders}, $header->{serial}, $header->{identifier},
                $header->{'file-sequence'},
            ),
        );
        $header->{'high-cylinder'} = $header->{cylinders};
    }

    return $header;
}

# The header of the CKD volume $volid, the source of a copy (move, clone, import), slack allowed
# (see parse_ckd_header()). $force_share if a running VM has it open.
sub ckd_copy_source_header {
    my ($storecfg, $volid, $force_share) = @_;

    my ($path, $format, $size) = volume_path_and_format($storecfg, $volid);
    my $header = eval { parse_ckd_header(read_image_head($path, $format, $force_share), $size, 1) };
    die "volume '$volid': $@" if $@;
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
    return ckd_header(
        $header->{cylinders}, $header->{serial}, $header->{identifier}, $header->{'file-sequence'},
    );
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
# the slack must not count as cylinders, then fit it (see fit_ckd_volume()). Returns the header of
# the volume, with the 'size' of the volume.
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
            $path,
            $format,
            ckd_header(
                $cylinders, $header->{serial}, $header->{identifier}, $header->{'file-sequence'},
            ),
        );
    }
    $header->{size} = fit_ckd_volume($storecfg, $volid, $header);

    return $header;
}

# Check an image to be imported as a CKD volume, before importing it, slack allowed (see
# parse_ckd_header()). Returns the parsed header, with the 'volser' of the volume if it has one.
sub check_ckd_import_source {
    my ($path, $format, $size) = @_;

    # the header and the first track, with the volume label
    my $blocks = (CKD_HEADER_SIZE + CKD_TRACK_SIZE) / 512;
    $blocks = int($size / 512) if $size < $blocks * 512;
    my $data = read_image_head($path, $format, undef, $blocks);
    my $header = eval { parse_ckd_header($data, $size, 1) };
    die "cannot import '$path' as CKD volume: $@" if $@;
    my $volser = ckd_volser($data);
    $header->{volser} = $volser if defined($volser);
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
# 'cutype', type and optional model, see PVE::QemuServer::Drive::parse_dasd_identity()), as a
# string to append to the device. They need a QEMU-mod build whose eckd-ccw and fba-ccw devices
# have the properties (uint16 type, uint8 model; model 0, left out here, is derived by QEMU).
# Also the 'cylinders' of a CKD volume, for QEMU-mod builds with that property.
my $identity_properties = {
    devtype => ['device-type', 'device-model'],
    cutype => ['control-unit-type', 'control-unit-model'],
};

sub identity_properties {
    my ($drive_id, $drive, $arch) = @_;

    my $res = '';
    # the cylinders of a CKD volume, for QEMU-mod builds that cross-check them with the header
    if ($drive->{interface} eq 'ckd' && defined($drive->{cylinders})) {
        my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
        $res .= ",cylinders=$drive->{cylinders}"
            if PVE::QemuServer::Helpers::kvm_device_has_property($binary, 'eckd-ccw', 'cylinders');
    }
    my $device = $drive->{interface} eq 'fba' ? 'fba-ccw' : 'eckd-ccw';
    for my $opt (sort keys %$identity_properties) {
        next if !defined($drive->{$opt});
        my ($type_prop, $model_prop) = $identity_properties->{$opt}->@*;
        my $binary = PVE::QemuServer::Helpers::get_command_for_arch($arch);
        die "$drive_id: '$opt' needs a QEMU with the '$type_prop' property of the $device device,"
            . " the installed one does not have it\n"
            if !PVE::QemuServer::Helpers::kvm_device_has_property($binary, $device, $type_prop);
        my ($type, $model) = eval { PVE::QemuServer::Drive::parse_dasd_identity($drive->{$opt}) };
        die "$drive_id: $opt: $@" if $@;
        $res .= ",$type_prop=$type";
        $res .= ",$model_prop=$model" if defined($model);
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
