package PVE::QemuServer::CCW;

# Device numbers (devnos) of the CCW devices of s390x VMs.
#
# The guest addresses a channel-attached device by its device number '0.<ssid>.<devno>' (channel
# subsystem, subchannel set, 16-bit device number). QEMU puts all emulated devices into the
# virtual channel subsystem 0xfe, which a guest without the multiple channel subsystems facility
# (MCSS-E, which no supported guest OS enables) sees as channel subsystem 0. Devices in any other
# channel subsystem would be invisible to the guest. So the configuration uses the device numbers
# as the guest sees them, '0.<ssid>.<devno>', and QEMU gets 'fe.<ssid>.<devno>'.
#
# Default ranges per device kind, in subchannel set 0. They are the ranges QEMU-mod uses for its
# automatic device numbers, which follow the conventions of mainframe installations
# (OSA at 0400, tape at 0580, 3270 terminals at 0700). A user can choose any free device
# number outside the reserved range, the defaults only serve the "next free" suggestion.
#
#   kind     range          devnos per device   QEMU device
#   virtio   0000 - 00ff    1                   virtio-*-ccw (reserved, assigned by qemu-server)
#   fba      0200 - 02ff    1                   fba-ccw (FBA DASD, 9336)
#   ckd      0300 - 03ff    1                   eckd-ccw (CKD DASD, 3390)
#   qeth     0400 - 04ff    3, base aligned to 4  qeth-ccw (OSA read/write/data triplet)
#   tape     0580 - 05ff    1                   3590-ccw (tape drive)
#   3270     0700 - 07ff    1                   x-terminal3270 (3270 terminal)
#
# qemu-server derives the device numbers of its virtio CCW devices from the fixed PCI slot map
# (see PVE::QemuServer::PCI::print_pci_addr()), they are below 0x0100. The whole range
# 0.0.0000-0.0.00ff is reserved for them, so no configured device number can collide with one.

use strict;
use warnings;

use PVE::JSONSchema;
use PVE::Tools;

my $devno_kinds = {
    virtio => { first => 0x0000, last => 0x00ff, count => 1, align => 1, reserved => 1 },
    fba => { first => 0x0200, last => 0x02ff, count => 1, align => 1 },
    ckd => { first => 0x0300, last => 0x03ff, count => 1, align => 1 },
    qeth => { first => 0x0400, last => 0x04ff, count => 3, align => 4 },
    tape => { first => 0x0580, last => 0x05ff, count => 1, align => 1 },
    3270 => { first => 0x0700, last => 0x07ff, count => 1, align => 1 },
};

# The configuration keys with a device number, the kind of their device and how many consecutive
# device numbers it uses. Each entry has a key pattern and a function that gets the key and the
# (unparsed) value and returns the kind and the configured device number (undef if not set), or
# nothing if the entry has no CCW device with a configurable device number.
my sub devno_property {
    my ($value) = @_;
    return $value =~ m/(?:^|,)devno=([^,]+)/ ? $1 : undef;
}

my $devno_users = [
    [qr/^fba\d+$/, sub { return ('fba', devno_property($_[1])); }],
    [qr/^ckd\d+$/, sub { return ('ckd', devno_property($_[1])); }],
];

=head3 register_devno_user($key_re, $code)

Register configuration keys that carry device numbers. C<$code> is called with the key and the
value and returns C<($kind, $devno)> (C<$devno> undef if the entry has none configured), or an
empty list if this entry has no device number.

=cut

sub register_devno_user {
    my ($key_re, $code) = @_;
    push $devno_users->@*, [$key_re, $code];
}

sub devno_kinds {
    return [sort keys %$devno_kinds];
}

sub devno_kind_info {
    my ($kind) = @_;
    my $info = $devno_kinds->{$kind} or die "unknown device number kind '$kind'\n";
    return $info;
}

=head3 parse_devno($devno)

Parse a device number as the guest sees it: C<0.<ssid>.<devno>> or just the 3 or 4 hex digits of
the device number (subchannel set 0). Returns C<($ssid, $devno)> as integers, dies on invalid
input.

=cut

sub parse_devno {
    my ($value) = @_;

    die "missing device number\n" if !defined($value) || $value eq '';

    my ($css, $ssid, $devno);
    if ($value =~ m/^([0-9a-f]{1,2})\.([0-3])\.([0-9a-f]{1,4})$/i) {
        ($css, $ssid, $devno) = (hex($1), $2, hex($3));
    } elsif ($value =~ m/^([0-9a-f]{3,4})$/i) {
        ($css, $ssid, $devno) = (0, 0, hex($1));
    } else {
        die "invalid device number '$value', expected 0.<ssid>.<devno> like 0.0.0200\n";
    }
    die "invalid device number '$value': the channel subsystem must be 0\n" if $css != 0;

    return ($ssid, $devno);
}

PVE::JSONSchema::register_format('pve-qm-ccw-devno', \&verify_devno);

sub verify_devno {
    my ($value, $noerr) = @_;

    my ($ssid, $devno) = eval { parse_devno($value) };
    if (my $err = $@) {
        return if $noerr;
        die $err;
    }
    return $value;
}

PVE::JSONSchema::register_format(
    'pve-qm-ccw-devno-list',
    sub {
        my ($value, $noerr) = @_;
        for my $devno (PVE::Tools::split_list($value)) {
            return if !defined(verify_devno($devno, $noerr));
        }
        return $value;
    },
);

# The canonical form: 0.<ssid>.<4 lower-case hex digits>
sub print_devno {
    my ($ssid, $devno) = @_;
    return sprintf("0.%d.%04x", $ssid, $devno);
}

sub normalize_devno {
    my ($value) = @_;
    return print_devno(parse_devno($value));
}

# The device number for the QEMU 'devno' property.
sub qemu_devno {
    my ($value) = @_;
    my ($ssid, $devno) = parse_devno($value);
    return sprintf("fe.%d.%04x", $ssid, $devno);
}

=head3 get_devno_users($conf, [$current_only], [$override])

All CCW devices with a configurable device number of a VM configuration, also the pending ones
(a pending value replaces the current one, pending deletions are left out) unless
C<$current_only> is set. C<$override> are further changes on top, key => value (undef deletes),
for example of devices about to be created. Returns a list of C<{ key, kind, devno, count }>;
C<devno> is undef if not configured.

=cut

sub get_devno_users {
    my ($conf, $current_only, $override) = @_;

    my $values = {};
    for my $key (keys %$conf) {
        next if ref($conf->{$key});
        $values->{$key} = $conf->{$key};
    }
    if (!$current_only && (my $pending = $conf->{pending})) {
        for my $key (keys %$pending) {
            next if $key eq 'delete' || ref($pending->{$key});
            $values->{$key} = $pending->{$key};
        }
        for my $key (PVE::Tools::split_list($pending->{delete} // '')) {
            $key =~ s/^!//;
            delete $values->{$key};
        }
    }

    for my $key (keys %{ $override // {} }) {
        if (defined($override->{$key})) {
            $values->{$key} = $override->{$key};
        } else {
            delete $values->{$key};
        }
    }

    my $res = [];
    for my $key (sort keys %$values) {
        for my $user ($devno_users->@*) {
            my ($re, $code) = $user->@*;
            next if $key !~ $re;
            my ($kind, $devno) = $code->($key, $values->{$key});
            last if !defined($kind);
            my $count = $devno_kinds->{$kind} ? $devno_kinds->{$kind}->{count} : 1;
            push @$res, { key => $key, kind => $kind, devno => $devno, count => $count };
            last;
        }
    }

    return $res;
}

# The used device numbers, as hash "<ssid>.<devno>" (integers) => key. Dies on an invalid devno.
my sub used_devnos {
    my ($users, $skip_key) = @_;

    my $used = {};
    for my $user ($users->@*) {
        next if defined($skip_key) && $user->{key} eq $skip_key;
        next if !defined($user->{devno});
        my ($ssid, $devno) = parse_devno($user->{devno});
        for my $i (0 .. $user->{count} - 1) {
            $used->{ "$ssid." . ($devno + $i) } = $user->{key};
        }
    }
    return $used;
}

my sub reserved_by {
    my ($ssid, $devno) = @_;

    return if $ssid != 0;
    for my $kind (sort keys %$devno_kinds) {
        my $info = $devno_kinds->{$kind};
        next if !$info->{reserved};
        return $kind if $devno >= $info->{first} && $devno <= $info->{last};
    }
    return;
}

=head3 check_devno_conflicts($conf, [$current_only], [$override])

Dies if a configured device number of the VM configuration (including the pending changes, unless
C<$current_only> is set, and C<$override>, see get_devno_users()) is invalid, in a reserved range,
leaves no room for all device numbers of the device, or is used twice.

=cut

sub check_devno_conflicts {
    my ($conf, $current_only, $override) = @_;

    my $users = get_devno_users($conf, $current_only, $override);
    my $used = {};
    for my $user ($users->@*) {
        next if !defined($user->{devno});
        my $key = $user->{key};
        my ($ssid, $devno) = eval { parse_devno($user->{devno}) };
        die "$key: $@" if $@;
        my $count = $user->{count};
        die "$key: device number $user->{devno} leaves no room for $count device numbers\n"
            if $devno + $count - 1 > 0xffff;
        my $info = $devno_kinds->{ $user->{kind} };
        if ($info && $info->{align} > 1 && $devno % $info->{align}) {
            die "$key: device number $user->{devno} must be a multiple of"
                . sprintf(" %x\n", $info->{align});
        }
        for my $i (0 .. $count - 1) {
            my $printed = print_devno($ssid, $devno + $i);
            if (my $reserved = reserved_by($ssid, $devno + $i)) {
                die "$key: device number $printed is reserved for the $reserved devices\n";
            }
            if (my $other = $used->{ "$ssid." . ($devno + $i) }) {
                die "$key: device number $printed is already used by $other\n";
            }
            $used->{ "$ssid." . ($devno + $i) } = $key;
        }
    }

    return;
}

=head3 next_free_devno($conf, $kind, [$extra_used], [$skip_key], [$override])

The next free device number for a device of C<$kind>: the first free and suitably aligned one in
the default range of the kind, then upwards from there, then from 0.0.0100. C<$conf> may be
undef (a VM that does not exist yet). C<$extra_used> is a list of further device numbers in use
(for example those of other devices being created at the same time), C<$skip_key> a config key
to ignore (the device whose number is chosen), C<$override> further changes (see
get_devno_users()). Returns the canonical form, dies if all are taken.

=cut

sub next_free_devno {
    my ($conf, $kind, $extra_used, $skip_key, $override) = @_;

    my $info = devno_kind_info($kind);
    die "device numbers of the $kind devices are assigned by qemu-server\n" if $info->{reserved};

    my $used = used_devnos(get_devno_users($conf // {}, 0, $override), $skip_key);
    for my $value (($extra_used // [])->@*) {
        my ($ssid, $devno) = parse_devno($value);
        $used->{"$ssid.$devno"} = 'extra';
    }

    my ($count, $align) = $info->@{qw(count align)};
    my $free = sub {
        my ($devno) = @_;
        return if $devno % $align || $devno + $count - 1 > 0xffff;
        for my $i (0 .. $count - 1) {
            return if $used->{ "0." . ($devno + $i) } || reserved_by(0, $devno + $i);
        }
        return 1;
    };

    for my $devno ($info->{first} .. 0xffff, 0x0100 .. $info->{first} - 1) {
        return print_devno(0, $devno) if $free->($devno);
    }

    die "no free device number for a $kind device\n";
}

1;
