package PVE::QemuServer::OVA;

# Export of a VM as OVA (an OVF descriptor, a manifest and the disk images in a tar archive), into
# the 'import' content of a storage, from where Proxmox VE imports it again (PVE::GuestImport::OVF).
#
# The OVF descriptor describes the VM with the standard resource types of the DMTF CIM, as far as
# they go: processors, memory, disk controllers and disks, NICs. What OVF has no resource types for
# is in a Proxmox VE configuration section (namespace $PVE_OVF_NS, ovf:required="false"; read by
# PVE::GuestImport::OVF): the configuration entries of the VM a Proxmox VE host needs to recreate it
# as it was. That keeps VirtIO devices, machine types and, on s390x, the DASDs (CKD and FBA), tape
# drives, 3270 terminals, qeth adapters and their device numbers, and the IPL device. Other OVF
# consumers see the generic description; Proxmox VE hosts without support for the section import
# the disks on their default controllers.
#
# Disk images are streamOptimized VMDK by default (the OVA norm, compressed), qcow2 (compressed) or
# raw on request. All three keep the content byte for byte: a CKD volume (a Hercules CKD image with
# its 512-byte header) is imported as the same volume. Tape media (ISO images content) are not
# included, only referenced: the import uses them if the same volume exists there.

use strict;
use warnings;

use Digest::SHA;
use File::Path;
use POSIX qw(strftime);

use PVE::Storage;
use PVE::Tools qw(run_command);

use PVE::QemuConfig;
use PVE::QemuServer;
use PVE::QemuServer::CCW;
use PVE::QemuServer::DASD;
use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Memory;
use PVE::QemuServer::Network;
use PVE::QemuServer::Tape;

our $PVE_OVF_NS = 'http://www.proxmox.com/schema/ovf';
our $PVE_OVF_SECTION_VERSION = 1;

my $format_info = {
    vmdk => {
        ext => 'vmdk',
        uri => 'http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized',
        options => ['-o', 'subformat=streamOptimized'],
    },
    qcow2 => {
        ext => 'qcow2',
        uri => 'https://www.qemu.org/docs/master/interop/qcow2.html',
        options => ['-c'],
    },
    raw => {
        ext => 'raw',
        uri => 'raw',
        options => [],
    },
};

sub disk_formats {
    return [sort keys %$format_info];
}

# CIM_OperatingSystem OsType per Proxmox VE OS type, see $ostype_ids in PVE::GuestImport::OVF
my $cim_ostype = {
    l24 => [98, 'Linux 2.4.x 64-Bit'],
    l26 => [101, 'Linux 64-Bit'],
    other => [1, 'Other'],
    solaris => [81, 'Solaris 64-Bit'],
    w2k => [58, 'Windows 2000'],
    w2k3 => [70, 'Microsoft Windows Server 2003 64-Bit'],
    w2k8 => [77, 'Microsoft Windows Server 2008 64-Bit'],
    wvista => [74, 'Windows Vista 64-Bit'],
    wxp => [67, 'Windows XP'],
    win7 => [105, 'Microsoft Windows 7'],
    win8 => [114, 'Microsoft Windows 8 64-bit'],
    win10 => [120, 'Microsoft Windows 10 64-bit'],
    win11 => [122, 'Microsoft Windows 11 64-bit'],
};

# Configuration entries written to the Proxmox VE section, see PVE::GuestImport::OVF for what an
# import takes from it. Drives and NICs are added as they are exported.
my $pve_section_keys = {
    map { $_ => 1 }
        qw(
        acpi agent balloon bios boot cores cpu cpuunits description ipl keyboard kvm localtime
        machine memory numa ostype scsihw shares sockets tablet tags vcpus vga
        )
};
my $pve_section_key_re = qr/^(?:terminal\d+|tape\d+|numa\d+)$/;

my sub xml_escape {
    my ($text) = @_;
    $text //= '';
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&apos;/g;
    $text =~ s/\n/&#10;/g;
    $text =~ s/([\x00-\x08\x0b\x0c\x0e-\x1f])//g;
    return $text;
}

my sub capacity_with_unit {
    my ($bytes) = @_;
    for my $exp (30, 20, 10) {
        my $unit = 2**$exp;
        return (int($bytes / $unit), "byte * 2^$exp") if $bytes % $unit == 0;
    }
    return ($bytes, 'byte');
}

my sub ckd_model_of {
    my ($cylinders) = @_;
    return '3390' if !defined($cylinders);
    my $models = PVE::QemuServer::DASD::ckd_models();
    for my $model (sort keys %$models) {
        return $model if $models->{$model} == $cylinders;
    }
    return '3390';
}

my sub drive_options {
    my ($drive) = @_;

    my $copy = {%$drive};
    delete $copy->@{qw(size format import-from)};
    $copy->{file} = 'none'; # printed first, as default key
    return PVE::QemuServer::Drive::print_drive($copy) =~ s/^none,?//r;
}

=head3 export_disks

    my $disks = export_disks($conf);

The drives of C<$conf> that go into an OVA, as list of C<{ key, drive }>, and warnings about what is
left out, as list of strings. Left out are CD-ROM and cloud-init drives, the EFI vars disk (an
import starts with fresh EFI vars) and TPM state.

=cut

sub export_disks {
    my ($conf) = @_;

    my $disks = [];
    my $warnings = [];
    PVE::QemuConfig->foreach_volume(
        $conf,
        sub {
            my ($key, $drive) = @_;

            return if PVE::QemuServer::Drive::drive_is_cdrom($drive, 1);
            return if !$drive->{file} || $drive->{file} eq 'none';
            if ($key eq 'efidisk0') {
                push @$warnings, "efidisk0: the EFI vars are not exported";
                return;
            }
            if ($key eq 'tpmstate0') {
                push @$warnings, "tpmstate0: the TPM state is not exported";
                return;
            }
            push @$disks, { key => $key, drive => $drive };
        },
    );
    @$disks = sort { $a->{key} cmp $b->{key} } @$disks;
    return ($disks, $warnings);
}

=head3 ovf_descriptor

    my $xml = ovf_descriptor($vmid, $conf, $disks, $arch);

The OVF descriptor for VM C<$vmid> with config C<$conf>. C<$disks> are the exported disks as list of
C<{ key, drive, href, file_size, capacity, format }> (C<format> is a key of C<disk_formats()>).

=cut

sub ovf_descriptor {
    my ($vmid, $conf, $disks, $arch) = @_;

    my $ns = $PVE_OVF_NS;
    my $name = $conf->{name} // "vm$vmid";
    my $ostype = $conf->{ostype} // 'other';
    my ($os_id, $os_desc) = ($cim_ostype->{$ostype} // $cim_ostype->{other})->@*;

    my $sockets = $conf->{sockets} // 1;
    my $cores = $conf->{cores} // 1;
    my $vcpus = $conf->{vcpus} // $sockets * $cores;
    my $memory = PVE::QemuServer::Memory::get_current_memory($conf->{memory});

    my $x = '';
    my $add = sub { $x .= join('', @_) . "\n" };

    $add->('<?xml version="1.0" encoding="UTF-8"?>');
    $add->('<!-- Generated by Proxmox VE (qm export-ova) -->');
    $add->(
        '<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"',
        ' xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"',
        ' xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"',
        ' xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"',
        ' xmlns:vmw="http://www.vmware.com/schema/ovf"',
        " xmlns:pve=\"$ns\">",
    );

    # References and DiskSection
    $add->('  <References>');
    for my $disk (@$disks) {
        $add->(
            "    <File ovf:id=\"file-$disk->{key}\" ovf:href=\"",
            xml_escape($disk->{href}),
            "\" ovf:size=\"$disk->{file_size}\"/>",
        );
    }
    $add->('  </References>');
    $add->('  <DiskSection>');
    $add->('    <Info>Virtual disk information</Info>');
    for my $disk (@$disks) {
        my ($capacity, $unit) = capacity_with_unit($disk->{capacity});
        $add->(
            "    <Disk ovf:diskId=\"$disk->{key}\" ovf:fileRef=\"file-$disk->{key}\"",
            " ovf:capacity=\"$capacity\" ovf:capacityAllocationUnits=\"$unit\"",
            " ovf:format=\"",
            xml_escape($format_info->{ $disk->{format} }->{uri}),
            "\"/>",
        );
    }
    $add->('  </DiskSection>');

    # NetworkSection: one network per bridge
    my $nets = [];
    for my $key (sort grep { m/^net\d+$/ } keys %$conf) {
        my $net = PVE::QemuServer::Network::parse_net($conf->{$key}, 1) or next;
        push @$nets, [$key, $net];
    }
    my %bridges = map { ($_->[1]->{bridge} // 'user') => 1 } @$nets;
    if (scalar(@$nets)) {
        $add->('  <NetworkSection>');
        $add->('    <Info>The logical networks</Info>');
        for my $bridge (sort keys %bridges) {
            $add->('    <Network ovf:name="', xml_escape($bridge), '">');
            $add->('      <Description>Bridge ', xml_escape($bridge), '</Description>');
            $add->('    </Network>');
        }
        $add->('  </NetworkSection>');
    }

    $add->("  <VirtualSystem ovf:id=\"", xml_escape($name), "\">");
    $add->('    <Info>A Proxmox VE virtual machine</Info>');
    $add->('    <Name>', xml_escape($name), '</Name>');
    $add->("    <OperatingSystemSection ovf:id=\"$os_id\">");
    $add->('      <Info>The guest operating system</Info>');
    $add->('      <Description>', xml_escape($os_desc), '</Description>');
    $add->('    </OperatingSystemSection>');

    $add->('    <VirtualHardwareSection>');
    $add->('      <Info>Virtual hardware requirements</Info>');
    $add->('      <System>');
    $add->('        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>');
    $add->('        <vssd:InstanceID>0</vssd:InstanceID>');
    $add->(
        '        <vssd:VirtualSystemIdentifier>',
        xml_escape($name),
        '</vssd:VirtualSystemIdentifier>',
    );
    $add->("        <vssd:VirtualSystemType>pve-qemu-$arch</vssd:VirtualSystemType>");
    $add->('      </System>');

    my $instance = 0;
    my $item = sub {
        my ($required, @fields) = @_;
        $instance++;
        my $attr = $required ? '' : ' ovf:required="false"';
        $add->("      <Item$attr>");
        my %f = @fields;
        $f{InstanceID} = $instance;
        # elements of rasd:CIM_ResourceAllocationSettingData_Type are in alphabetical order
        for my $field (sort keys %f) {
            next if !defined($f{$field});
            $add->("        <rasd:$field>", xml_escape($f{$field}), "</rasd:$field>");
        }
        $add->('      </Item>');
        return $instance;
    };

    $item->(
        1,
        AllocationUnits => 'hertz * 10^6',
        Description => 'Number of virtual CPUs',
        ElementName => "$vcpus virtual CPU(s)",
        ResourceType => 3,
        VirtualQuantity => $vcpus,
    );
    $item->(
        1,
        AllocationUnits => 'byte * 2^20',
        Description => 'Memory size',
        ElementName => "${memory}MB of memory",
        ResourceType => 4,
        VirtualQuantity => $memory,
    );

    # Disk controllers. Importers number the disks of a controller type by AddressOnParent
    # (Proxmox VE maps 'other storage device' to SATA), so all type 20 controllers share one count.
    my $controller_info = {
        ide => [5, 'PIIX4', 'IDE controller'],
        scsi => [6, $conf->{scsihw} // 'lsi', 'SCSI controller'],
        sata => [20, 'AHCI', 'SATA controller'],
        virtio => [20, 'virtio-blk', 'VirtIO block devices'],
        fba => [20, 's390-css', 'Channel subsystem (DASD)'],
        ckd => [20, 's390-css', 'Channel subsystem (DASD)'],
    };
    my $controllers = {};
    my $address = {};
    for my $disk (@$disks) {
        my $bus = $disk->{drive}->{interface};
        my ($type, $subtype, $desc) = $controller_info->{$bus}->@*;
        my $ctrl_key = "$type:$subtype";
        $controllers->{$ctrl_key} //= $item->(
            1,
            Address => 0,
            Description => $desc,
            ElementName => $desc,
            ResourceSubType => $subtype,
            ResourceType => $type,
        );
        my $count_key = $type == 20 ? 20 : $ctrl_key;
        my $addr = $address->{$count_key}++ // 0;
        $addr = $disk->{drive}->{index} if $type != 20; # ide1, scsi3: as configured

        my $drive = $disk->{drive};
        my ($desc_disk, $subtype_disk, $devno);
        if ($bus eq 'ckd') {
            $subtype_disk = ckd_model_of($drive->{cylinders});
            $devno = $drive->{devno};
            $desc_disk = "IBM $subtype_disk CKD DASD";
            $desc_disk .= ", $drive->{cylinders} cylinders" if $drive->{cylinders};
        } elsif ($bus eq 'fba') {
            $subtype_disk = '9336';
            $devno = $drive->{devno};
            $desc_disk = 'IBM 9336 FBA DASD';
        } else {
            $desc_disk = "Hard disk $disk->{key}";
        }
        $desc_disk .= ", device $devno" if defined($devno);
        $item->(
            1,
            Address => $devno,
            AddressOnParent => $addr,
            Description => $desc_disk,
            ElementName => $disk->{key},
            HostResource => "ovf:/disk/$disk->{key}",
            Parent => $controllers->{$ctrl_key},
            ResourceSubType => $subtype_disk,
            ResourceType => 17,
        );
    }

    for my $entry (@$nets) {
        my ($key, $net) = @$entry;
        $item->(
            1,
            Address => $net->{macaddr},
            AutomaticAllocation => 'true',
            Connection => $net->{bridge} // 'user',
            Description => "$net->{model} network adapter $key"
                . (defined($net->{devno}) ? ", device $net->{devno}" : ''),
            ElementName => $key,
            ResourceSubType => $net->{model},
            ResourceType => 10,
        );
    }

    for my $key (sort grep { PVE::QemuServer::Tape::is_tape_key($_) } keys %$conf) {
        my $tape = PVE::QemuServer::Tape::parse_tape($conf->{$key});
        my ($index) = $key =~ m/(\d+)$/;
        my $devno =
            defined($tape->{devno})
            ? PVE::QemuServer::CCW::normalize_devno($tape->{devno})
            : sprintf('0.0.%04x', 0x0580 + $index);
        my $ident = $tape->{ident} // '3590';
        my $medium = $tape->{file} // 'none';
        $item->(
            0,
            Address => $devno,
            Description => "IBM $ident tape drive"
                . ($medium ne 'none' ? ", medium $medium (not included)" : ''),
            ElementName => $key,
            ResourceSubType => $ident,
            ResourceType => 18,
        );
    }

    for my $key (
        sort { ($a =~ s/\D//gr) <=> ($b =~ s/\D//gr) }
        grep { m/^terminal\d+$/ } keys %$conf
    ) {
        my $term = PVE::QemuServer::parse_terminal($conf->{$key});
        my $model = defined($term->{model}) ? "3270-$term->{model}" : '3270';
        $item->(
            0,
            Address => $term->{devno},
            Description => "IBM $model display terminal",
            ElementName => $key,
            OtherResourceType => 'IBM 3270 display terminal',
            ResourceSubType => $model,
            ResourceType => 1,
        );
    }

    if (($conf->{bios} // '') eq 'ovmf') {
        $add->('      <vmw:Config ovf:required="false" vmw:key="firmware" vmw:value="efi"/>');
    }
    $add->('    </VirtualHardwareSection>');

    # The Proxmox VE configuration section
    $add->(
        "    <pve:ConfigSection ovf:required=\"false\"",
        " pve:version=\"$PVE_OVF_SECTION_VERSION\" pve:arch=\"$arch\">",
    );
    $add->('      <Info>Proxmox VE virtual machine configuration</Info>');
    my $entry = sub {
        my ($key, $value, $disk_id) = @_;
        my $disk_attr = defined($disk_id) ? " pve:diskId=\"$disk_id\"" : '';
        $add->(
            "      <pve:Config pve:key=\"$key\" pve:value=\"",
            xml_escape($value),
            "\"$disk_attr/>",
        );
    };
    my %exported = map { $_->{key} => 1 } @$disks;
    $exported{ $_->[0] } = 1 for @$nets;
    for my $key (sort keys %$conf) {
        next if !$pve_section_keys->{$key} && $key !~ $pve_section_key_re;
        next if ref($conf->{$key});
        my $value = $conf->{$key};
        if ($key eq 'boot') {
            # only the devices that are exported
            next if $value !~ m/^order=([^,]*)$/;
            my @order = grep { $exported{$_} } split(/;/, $1);
            next if !scalar(@order);
            $value = 'order=' . join(';', @order);
        }
        $entry->($key, $value);
    }
    for my $key (sort grep { m/^serial\d+$/ } keys %$conf) {
        $entry->($key, $conf->{$key}) if $conf->{$key} eq 'socket';
    }
    $entry->($_->{key}, drive_options($_->{drive}), $_->{key}) for @$disks;
    $entry->($_->[0], $conf->{ $_->[0] }) for @$nets;
    $add->('    </pve:ConfigSection>');

    $add->('  </VirtualSystem>');
    $add->('</Envelope>');

    return $x;
}

=head3 ova_name

    my $name = ova_name($vmid, $conf, $filename);

The base name of the OVA file: C<$filename> without '.ova', or the VM name, or 'vm<vmid>'.

=cut

sub ova_name {
    my ($vmid, $conf, $filename) = @_;

    my $name = $filename // $conf->{name} // "vm$vmid";
    $name =~ s/\.ova$//i;
    die "invalid OVA file name '$name'\n"
        if $name !~ m/^${PVE::Storage::SAFE_CHAR_CLASS_RE}+$/ || $name =~ m/^\./;
    return $name;
}

=head3 export_ova

    my $volid = export_ova($storecfg, $vmid, $storeid, $opts);

Export the stopped VM C<$vmid> as OVA into the 'import' content of storage C<$storeid>. Options
in C<$opts>: C<filename> (default: VM name), C<format> (disk image format, default 'vmdk').
Returns the volume ID of the OVA. Runs in a worker; the VM is locked ('export') meanwhile.

=cut

sub export_ova {
    my ($storecfg, $vmid, $storeid, $opts) = @_;

    my $format = $opts->{format} // 'vmdk';
    my $finfo = $format_info->{$format} or die "unknown disk format '$format'\n";

    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
    die "storage '$storeid' does not have the 'import' content type\n"
        if !$scfg->{content}->{import};
    PVE::Storage::activate_storage($storecfg, $storeid);
    my $import_dir = PVE::Storage::get_import_dir($storecfg, $storeid);
    die "storage '$storeid' has no import directory\n" if !$import_dir;
    File::Path::make_path($import_dir);

    my $conf = PVE::QemuConfig->load_config($vmid);
    my $name = ova_name($vmid, $conf, $opts->{filename});
    my $ova_path = "$import_dir/$name.ova";
    die "'$storeid:import/$name.ova' already exists\n" if -e $ova_path;

    PVE::QemuConfig->lock_config(
        $vmid,
        sub {
            $conf = PVE::QemuConfig->load_config($vmid);
            PVE::QemuConfig->check_lock($conf);
            die "VM $vmid is running - stop it first, an export needs consistent disks\n"
                if PVE::QemuServer::Helpers::vm_running_locally($vmid);
            $conf->{lock} = 'export';
            PVE::QemuConfig->write_config($vmid, $conf);
        },
    );

    my $stage = "$import_dir/.export-$vmid-$$";
    my $tmp_ova = "$import_dir/.$name.ova.tmp";
    my $volid = "$storeid:import/$name.ova";
    eval {
        delete $conf->{lock};
        my $arch = PVE::QemuServer::Helpers::get_vm_arch($conf);
        my ($disks, $warnings) = export_disks($conf);
        warn "warning: $_\n" for @$warnings;

        File::Path::make_path($stage);
        my $manifest = '';
        my $sha = sub {
            my ($file) = @_;
            my $digest = Digest::SHA->new(256);
            $digest->addfile("$stage/$file");
            $manifest .= "SHA256($file)= " . $digest->hexdigest() . "\n";
        };

        my @volids = map { $_->{drive}->{file} } @$disks;
        PVE::Storage::activate_volumes($storecfg, \@volids) if scalar(@volids);
        for my $disk (@$disks) {
            my $src = $disk->{drive}->{file};
            my $path = PVE::Storage::path($storecfg, $src);
            my $src_format = PVE::QemuServer::Drive::checked_volume_format($storecfg, $src);
            my $capacity = PVE::Storage::volume_size_info($storecfg, $src)
                or die "$disk->{key}: could not get the size of '$src'\n";

            my $file = "$name-$disk->{key}.$finfo->{ext}";
            print "$disk->{key}: exporting '$src' to $file ($format)\n";
            run_command(
                [
                    '/usr/bin/qemu-img',
                    'convert',
                    '-p',
                    '-f',
                    $src_format,
                    '-O',
                    $format,
                    $finfo->{options}->@*,
                    $path,
                    "$stage/$file",
                ],
                errmsg => "$disk->{key}: unable to export '$src'",
            );
            $disk->{href} = $file;
            $disk->{file_size} = -s "$stage/$file";
            $disk->{capacity} = $capacity;
            $disk->{format} = $format;
        }

        my $ovf = "$name.ovf";
        PVE::Tools::file_set_contents(
            "$stage/$ovf",
            ovf_descriptor($vmid, $conf, $disks, $arch),
        );
        $sha->($ovf);
        $sha->($_->{href}) for @$disks;
        my $mf = "$name.mf";
        PVE::Tools::file_set_contents("$stage/$mf", $manifest);

        # ustar unless a file is too large for it (8 GiB): then GNU tar's base-256 sizes, as other
        # OVA writers do
        my @files = ($ovf, $mf, map { $_->{href} } @$disks);
        my $large = grep { (-s "$stage/$_") >= 8 * 1024**3 } @files;
        print "writing $volid\n";
        run_command(
            [
                'tar',
                '-c',
                '--format=' . ($large ? 'gnu' : 'ustar'),
                '--owner=0',
                '--group=0',
                '--numeric-owner',
                '--mode=0644',
                '--remove-files',
                '-f',
                $tmp_ova,
                '-C',
                $stage,
                '--',
                @files,
            ],
            errmsg => "unable to write the OVA",
        );
        rename($tmp_ova, $ova_path) or die "unable to rename '$tmp_ova' to '$ova_path' - $!\n";
    };
    my $err = $@;

    File::Path::remove_tree($stage) if -d $stage;
    unlink $tmp_ova if -e $tmp_ova;
    eval {
        PVE::QemuConfig->lock_config(
            $vmid,
            sub {
                my $conf = PVE::QemuConfig->load_config($vmid);
                if (($conf->{lock} // '') eq 'export') {
                    delete $conf->{lock};
                    PVE::QemuConfig->write_config($vmid, $conf);
                }
            },
        );
    };
    warn "unable to remove the export lock of VM $vmid - $@" if $@;
    die "export of VM $vmid failed: $err" if $err;

    print "exported VM $vmid to $volid\n";
    return $volid;
}

1;
