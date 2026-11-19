package PVE::QemuServer::ImportDisk;

use strict;
use warnings;

use File::Path;

use PVE::Storage;
use PVE::Tools qw(run_command extract_param);

use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::DASD;
use PVE::QemuServer::Drive;
use PVE::QemuServer::QemuImage;

# imports an external disk image to an existing VM
# and creates by default a drive entry unused[n] pointing to the created volume
# $params->{drive_name} may be used to specify ide0, scsi1, etc ...
# $params->{format} may be used to specify qcow2, raw, etc ...
# $params->{skiplock} may be used to skip checking for a lock in the VM config
# $params->{'skip-config-update'} may be used to import the disk without updating the VM config
# $params->{'volume-name'} may be the name for the volume, 'vm-<vmid>-<name>' if it is free
sub do_import {
    my ($src_path, $src_size, $vmid, $storage_id, $params) = @_;

    my $drive_name = extract_param($params, 'drive_name');
    my $format = extract_param($params, 'format');
    if ($drive_name && !(PVE::QemuServer::is_valid_drivename($drive_name))) {
        die "invalid drive name: $drive_name\n";
    }

    # get target format, target image's path, and whether it's possible to sparseinit
    my $storecfg = PVE::Storage::config();
    my $dst_format =
        PVE::QemuServer::resolve_dst_disk_format($storecfg, $storage_id, undef, $format);
    warn "format '$format' is not supported by the target storage - using '$dst_format' instead\n"
        if $format && $format ne $dst_format;

    # a DASD keeps the name of its source volume, if it is free
    my $volume_name = extract_param($params, 'volume-name');
    my $dst_volid = PVE::QemuServer::DASD::alloc_named_volume(
        $storecfg, $storage_id, $vmid, $dst_format, $volume_name, $src_size / 1024,
        $drive_name // 'import',
    );

    my $zeroinit = PVE::Storage::volume_has_feature($storecfg, 'sparseinit', $dst_volid);

    my $create_drive = sub {
        my $vm_conf = PVE::QemuConfig->load_config($vmid);
        if (!$params->{skiplock}) {
            PVE::QemuConfig->check_lock($vm_conf);
        }

        if ($drive_name) {
            # should never happen as setting $drive_name is not exposed to public interface
            die "cowardly refusing to overwrite existing entry: $drive_name\n"
                if $vm_conf->{$drive_name};

            my $modified = {}; # record what $option we modify
            $modified->{$drive_name} = 1;
            $vm_conf->{pending}->{$drive_name} = $dst_volid;
            PVE::QemuConfig->write_config($vmid, $vm_conf);

            my $running = PVE::QemuServer::check_running($vmid);
            if ($running) {
                my $errors = {};
                PVE::QemuServer::vmconfig_hotplug_pending(
                    $vmid,
                    $vm_conf,
                    $storecfg,
                    $modified,
                    $errors,
                );
                warn "hotplugging imported disk '$_' failed: $errors->{$_}\n" for keys %$errors;
            } else {
                PVE::QemuServer::vmconfig_apply_pending($vmid, $vm_conf, $storecfg);
            }
        } else {
            $drive_name = PVE::QemuConfig->add_unused_volume($vm_conf, $dst_volid);
            PVE::QemuConfig->write_config($vmid, $vm_conf);
        }
    };

    eval {
        # trap interrupts so we have a chance to clean up
        local $SIG{INT} = local $SIG{TERM} = local $SIG{QUIT} = local $SIG{HUP} =
            local $SIG{PIPE} = sub { die "interrupted by signal $!\n"; };

        PVE::Storage::activate_volumes($storecfg, [$dst_volid]);
        PVE::QemuServer::QemuImage::convert(
            $src_path,
            $dst_volid,
            $src_size,
            { 'is-zero-initialized' => $zeroinit },
        );
        PVE::Storage::deactivate_volumes($storecfg, [$dst_volid]);
        PVE::QemuConfig->lock_config($vmid, $create_drive) if !$params->{'skip-config-update'};
    };
    if (my $err = $@) {
        eval { PVE::Storage::vdisk_free($storecfg, $dst_volid) };
        warn "cleanup of $dst_volid failed: $@\n" if $@;
        die $err;
    }

    return ($drive_name, $dst_volid);
}

# Extracts the disk image $volid ('<storage>:import/<name>.ova/<file>') of an OVA into a new
# temporary directory on the file based storage $working_storeid, as '<drive>.<format>'. The storage needs no 'images' content: the image is only read from there, by the
# import of the disk. Returns the path of the image, its format and the directory, which the
# caller removes (File::Path::remove_tree) when the import is done.
sub extract_ova_disk {
    my ($storecfg, $volid, $vmid, $drive_name, $working_storeid) = @_;

    my ($source_storeid) = PVE::Storage::parse_volume_id($volid);
    my ($vtype, $name, undef, undef, undef, undef, $fmt) =
        PVE::Storage::parse_volname($storecfg, $volid);
    die "only files with content type 'import' can be extracted\n" if $vtype ne 'import';
    my ($inner_fmt) = ($fmt // '') =~ m/^ova\+(.+)$/
        or die "only files from 'ova' format can be extracted\n";
    die "'$volid' is a tape medium, not a disk image\n" if $inner_fmt eq 'aws';
    die "cannot extract $volid - invalid format '$inner_fmt'\n"
        if $inner_fmt !~ m/^($PVE::QemuServer::Drive::QEMU_FORMAT_RE)$/;
    my ($archive, $inner_file) =
        $name =~ m!^(.*\.ova)/(${PVE::Storage::SAFE_CHAR_WITH_WHITESPACE_CLASS_RE}+)$!
        or die "cannot extract $volid - invalid volume name\n";
    my $ova_path = PVE::Storage::path($storecfg, "$source_storeid:import/$archive");

    my $scfg = PVE::Storage::storage_config($storecfg, $working_storeid);
    die "import working storage '$working_storeid' is not file based\n" if !$scfg->{path};
    PVE::Storage::activate_storage($storecfg, $working_storeid);
    my $dir = "$scfg->{path}/.import-tmp-$vmid-$$";
    File::Path::make_path($dir, { mode => 0700 });

    my $path = "$dir/$drive_name.$inner_fmt";
    eval {
        run_command([
            'tar',
            '-x',
            '--force-local',
            '--no-same-owner',
            '-C',
            $dir,
            '-f',
            $ova_path,
            '--',
            $inner_file,
        ]);
        my $extracted = "$dir/$inner_file";
        die "extracted file '$inner_file' from '$ova_path' is not a regular file\n"
            if -l $extracted || !-f $extracted;
        if ($extracted ne $path) {
            rename($extracted, $path) or die "unable to rename '$extracted' - $!\n";
        }
        # check the untrusted image file
        PVE::Storage::file_size_info($path, undef, $inner_fmt, 1);
    };
    if (my $err = $@) {
        File::Path::remove_tree($dir);
        die "error during extraction: $err";
    }

    return ($path, $inner_fmt, $dir);
}

1;
