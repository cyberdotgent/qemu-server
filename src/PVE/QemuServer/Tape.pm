package PVE::QemuServer::Tape;

# Channel-attached tape drives of s390x VMs (the 3590-ccw device of QEMU builds with mainframe
# support), with an AWSTAPE image as removable medium. Mainframe operating systems are installed
# from tape: a tape drive can be the IPL device. Media are read-only and can be changed while the
# VM runs, like a CD-ROM.

use strict;
use warnings;

use JSON;

use PVE::JSONSchema qw(parse_property_string print_property_string);
use PVE::GuestImport;
use PVE::Storage;

use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

our $MAX_TAPE_DRIVES = 4;

# Device numbers of the tape drives: the conventional 0580 and up, unless configured.
my $DEFAULT_DEVNO_BASE = 0x0580;

PVE::JSONSchema::register_format('pve-qm-tape-file', \&verify_tape_file);

sub verify_tape_file {
    my ($value, $noerr) = @_;

    return $value if $value eq 'none';
    return PVE::QemuServer::Drive::verify_volume_id_or_absolute_path($value, $noerr);
}

my $tape_fmt = {
    file => {
        default_key => 1,
        type => 'string',
        format => 'pve-qm-tape-file',
        format_description => 'volume',
        description => "The tape image (AWSTAPE) in the tape drive, an ISO images volume like"
            . " 'local:iso/install.aws', or 'none' for an empty drive.",
    },
    devno => {
        type => 'string',
        pattern => '(?:0\.[0-3]\.[0-9a-fA-F]{1,4}|[0-9a-fA-F]{3,4})',
        optional => 1,
        format_description => '0.<ssid>.<devno>',
        description => "The device number of the tape drive as the guest sees it, for example"
            . " '0.0.0580'. Defaults to 0.0.0580 for tape0, 0.0.0581 for tape1 and so on.",
    },
    'import-from' => {
        type => 'string',
        format => 'pve-volume-id',
        format_description => 'source volume',
        optional => 1,
        description => "Only when creating or changing the drive: import the medium from a tape"
            . " image (AWSTAPE) in an OVA, '<storage>:import/<name>.ova/<file>.aws', into the ISO"
            . " images content of the storage given as medium '<storage>:0'.",
    },
    ident => {
        type => 'string',
        enum => [qw(3410 3411 3420 3422 3430 3480 3490 3590 8809 9347 9348)],
        optional => 1,
        default => '3590',
        description => "The tape drive type reported to the guest. Some guests select their tape"
            . " driver by it. The commands are the ones of a 3590 in any case.",
    },
};
PVE::JSONSchema::register_format('pve-qm-tape', $tape_fmt);

our $tape_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-tape',
    description => "A tape drive of an s390x VM (needs a QEMU build with the 3590-ccw device),"
        . " with a read-only AWSTAPE image as medium.",
};

sub valid_tape_keys {
    return map { "tape$_" } (0 .. $MAX_TAPE_DRIVES - 1);
}

sub is_tape_key {
    my ($key) = @_;
    return $key =~ m/^tape(\d+)$/ && $1 < $MAX_TAPE_DRIVES;
}

sub parse_tape {
    my ($value) = @_;
    return parse_property_string($tape_fmt, $value);
}

sub print_tape {
    my ($tape) = @_;
    return print_property_string($tape, $tape_fmt);
}

# The CCW device number of a tape drive, in the 'fe.<ssid>.<devno>' form QEMU uses (the guest sees
# channel subsystem 0xfe as 0).
sub get_devno {
    my ($key, $tape) = @_;

    my ($index) = $key =~ m/^tape(\d+)$/;
    my ($ssid, $devno) = (0, $DEFAULT_DEVNO_BASE + $index);
    if (defined(my $value = $tape->{devno})) {
        ($ssid, $devno) = $value =~ m/^0\.([0-3])\.([0-9a-f]+)$/i ? ($1, hex($2)) : (0, hex($value));
    }
    return sprintf('fe.%x.%04x', $ssid, $devno);
}

# The tape drives of a config, as [key, parsed value] sorted by key. Dies on duplicate device
# numbers.
sub get_tapes {
    my ($conf) = @_;

    my $res = [];
    my $devnos = {};
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = parse_tape($conf->{$key});
        my $devno = get_devno($key, $tape);
        die "$key: device number $devno is already used by $devnos->{$devno}\n"
            if $devnos->{$devno};
        $devnos->{$devno} = $key;
        push @$res, [$key, $tape];
    }

    return $res;
}

my sub import_target_storage {
    my ($tape) = @_;
    return $tape->{file} =~ m/^([^:\/]+):0$/ ? $1 : undef;
}

=head3 media_imports($param)

The tape drives of the parameters C<$param> of a VM creation or change whose medium is imported
from an OVA (option 'import-from'), as list of C<[$key, $source, $storeid]>. Dies if the target is
not given as '<storage>:0'.

=cut

sub media_imports {
    my ($param) = @_;

    my $res = [];
    for my $key (valid_tape_keys()) {
        next if !defined($param->{$key});
        my $tape = parse_tape($param->{$key});
        next if !defined($tape->{'import-from'});
        my $storeid = import_target_storage($tape)
            or die "$key: give the storage for the imported medium as '<storage>:0'\n";
        push @$res, [$key, $tape->{'import-from'}, $storeid];
    }
    return $res;
}

=head3 import_media($param)

Import the media of the tape drives in the parameters C<$param> that have 'import-from' into the
ISO images content of their storage, and replace the values with the imported media.

=cut

sub import_media {
    my ($param) = @_;

    for my $import (media_imports($param)->@*) {
        my ($key, $source, $storeid) = @$import;
        my $tape = parse_tape($param->{$key});
        print "$key: importing medium '$source' to storage '$storeid'\n";
        $tape->{file} = PVE::GuestImport::extract_media_from_import_file($source, $storeid);
        delete $tape->{'import-from'};
        $param->{$key} = print_tape($tape);
    }
    return;
}

# The volumes of the tape media of a config, for activation.
sub get_volumes {
    my ($conf) = @_;

    my $res = [];
    for my $key (valid_tape_keys()) {
        next if !$conf->{$key};
        my $tape = eval { parse_tape($conf->{$key}) } or next;
        my $file = $tape->{file};
        next if $file eq 'none' || $file =~ m|^/|;
        push @$res, $file;
    }
    return $res;
}

my sub tape_path {
    my ($storecfg, $file) = @_;

    return undef if $file eq 'none';
    return $file if $file =~ m|^/|;
    return PVE::Storage::path($storecfg, $file);
}

# The QEMU arguments for the tape drives of a config.
sub get_command_args {
    my ($storecfg, $conf, $arch, $kvm_binary) = @_;

    my $tapes = get_tapes($conf);
    return [] if !@$tapes;

    die "tape drives are only supported on s390x\n" if $arch ne 's390x';
    die "the installed QEMU has no tape drive (3590-ccw)\n"
        if !PVE::QemuServer::Helpers::kvm_device_types($kvm_binary)->{'3590-ccw'};

    my $args = [];
    for my $entry (@$tapes) {
        my ($key, $tape) = @$entry;
        die "$key: 'import-from' is only for creating or changing the tape drive\n"
            if defined($tape->{'import-from'});
        my $device = "3590-ccw,id=$key,devno=" . get_devno($key, $tape);
        if (defined(my $path = tape_path($storecfg, $tape->{file}))) {
            $path =~ s/,/,,/g;
            push @$args, '-drive', "if=none,id=drive-$key,file=$path,format=raw,read-only=on";
            $device .= ",drive=drive-$key";
        }
        $device .= ",ident=$tape->{ident}" if defined($tape->{ident});
        push @$args, '-device', $device;
    }

    return $args;
}

# Change the medium of a tape drive of a running VM. Only the medium can change, everything else
# needs a restart.
sub change_medium {
    my ($storecfg, $vmid, $key, $old_value, $new_value) = @_;

    my $old = parse_tape($old_value);
    my $new = parse_tape($new_value);
    for my $opt (qw(devno ident)) {
        return 0 if ($old->{$opt} // '') ne ($new->{$opt} // '');
    }
    return 1 if $old->{file} eq $new->{file};

    mon_cmd($vmid, 'eject', id => $key, force => JSON::true);
    if (defined(my $path = tape_path($storecfg, $new->{file}))) {
        PVE::Storage::activate_volumes($storecfg, [$new->{file}]) if $new->{file} !~ m|^/|;
        mon_cmd(
            $vmid, 'blockdev-change-medium',
            id => $key,
            filename => $path,
            format => 'raw',
            'read-only-mode' => 'read-only',
        );
    }

    return 1;
}

1;
