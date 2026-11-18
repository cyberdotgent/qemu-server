package PVE::QemuServer::Helpers;

use strict;
use warnings;

use File::stat;
use IO::File;
use JSON;

use PVE::INotify;
use PVE::ProcFSTools;
use PVE::Tools;

use base 'Exporter';
our @EXPORT_OK = qw(
    min_version
    config_aware_timeout
    get_iscsi_initiator_name
    kvm_machine_types
    kvm_user_version
    parse_number_sets
    windows_version
    get_host_arch
    version_parts
);

my $nodename = PVE::INotify::nodename();

my $arch_to_qemu_binary = {
    aarch64 => '/usr/bin/qemu-system-aarch64',
    x86_64 => '/usr/bin/qemu-system-x86_64',
};

# wrapper around the Tools helper, having it here makes it easier to mock for testing
sub get_host_arch {
    return PVE::Tools::get_host_arch();
}

sub get_command_for_arch($) {
    my ($arch) = @_;
    return '/usr/bin/kvm' if get_host_arch() eq $arch; # i.e. native arch

    my $cmd = $arch_to_qemu_binary->{$arch}
        or die "don't know how to emulate architecture '$arch'\n";
    return $cmd;
}

sub get_vm_arch {
    my ($conf) = @_;
    return $conf->{arch} // get_host_arch();
}

my $kvm_user_version = {};
my $kvm_is_qemu_mod = {};
my $kvm_mtime = {};

sub kvm_user_version {
    my ($binary) = @_;

    $binary //= get_command_for_arch(get_host_arch()); # get the native arch by default
    my $st = stat($binary);

    my $cachedmtime = $kvm_mtime->{$binary} // -1;
    return $kvm_user_version->{$binary}
        if $kvm_user_version->{$binary}
        && $cachedmtime == $st->mtime;

    $kvm_user_version->{$binary} = 'unknown';
    $kvm_is_qemu_mod->{$binary} = 0;
    $kvm_mtime->{$binary} = $st->mtime;

    my $code = sub {
        my $line = shift;
        if ($line =~ m/^QEMU(-mod)?( PC)? emulator version (\d+\.\d+(\.\d+)?)(\.\d+)?[,\s]/) {
            $kvm_user_version->{$binary} = $3;
            $kvm_is_qemu_mod->{$binary} = defined($1) ? 1 : 0;
        }
    };

    eval { PVE::Tools::run_command([$binary, '--version'], outfunc => $code); };
    warn $@ if $@;

    return $kvm_user_version->{$binary};
}

# Whether the QEMU binary is a QEMU-mod build, detected together with its version. QEMU-mod
# follows upstream master, so an X.Y.90 version is its normal state there, not a release candidate.
sub kvm_is_qemu_mod {
    my ($binary) = @_;

    $binary //= get_command_for_arch(get_host_arch());
    kvm_user_version($binary); # parses --version once, cached with the version

    return $kvm_is_qemu_mod->{$binary} // 0;
}

my $kvm_device_types = {};
my $kvm_device_types_mtime = {};

# Returns a hash with the names of the device types the QEMU binary supports.
sub kvm_device_types {
    my ($binary) = @_;

    my $st = stat($binary) or die "unable to stat QEMU binary '$binary' - $!\n";

    return $kvm_device_types->{$binary}
        if $kvm_device_types->{$binary}
        && ($kvm_device_types_mtime->{$binary} // -1) == $st->mtime;

    my $types = {};
    my $code = sub {
        my $line = shift;
        $types->{$1} = 1 if $line =~ m/^name "([^"]+)"/;
    };

    PVE::Tools::run_command([$binary, '-device', 'help'], outfunc => $code);

    $kvm_device_types->{$binary} = $types;
    $kvm_device_types_mtime->{$binary} = $st->mtime;

    return $types;
}

my $kvm_machine_types = {};
my $kvm_machine_types_mtime = {};

# Returns a hash with the names of the machine types (including aliases) the QEMU binary supports,
# and their descriptions as values.
sub kvm_machine_types {
    my ($binary) = @_;

    my $st = stat($binary) or die "unable to stat QEMU binary '$binary' - $!\n";

    return $kvm_machine_types->{$binary}
        if $kvm_machine_types->{$binary}
        && ($kvm_machine_types_mtime->{$binary} // -1) == $st->mtime;

    my $types = {};
    my $list_started;
    my $code = sub {
        my $line = shift;
        if (!$list_started) {
            $list_started = $line =~ m/^Supported machines are:/;
        } elsif ($line =~ m/^(\S+)\s*(.*?)\s*$/) {
            $types->{$1} = length($2) ? $2 : $1;
        }
    };

    PVE::Tools::run_command([$binary, '-machine', 'help'], outfunc => $code);

    $kvm_machine_types->{$binary} = $types;
    $kvm_machine_types_mtime->{$binary} = $st->mtime;

    return $types;
}

# Without the 'iplable' and 'ipl-method' device properties, QEMU's s390-ccw firmware can IPL from
# virtio block and network devices and from SCSI disks and CD-ROMs, selected with bootindex.
my $default_ipl_methods =
    { map { $_ => 'firmware' } qw(virtio-blk-ccw virtio-net-ccw scsi-hd scsi-cd scsi-block) };

my $kvm_ipl_methods = {};
my $kvm_ipl_methods_mtime = {};

# The default values of the properties of QEMU device types, from one QMP session.
my sub query_device_type_properties {
    my ($binary, $types) = @_;

    my @commands = ({ execute => 'qmp_capabilities' });
    push @commands,
        map { { execute => 'device-list-properties', arguments => { typename => $_ }, id => $_ } }
        @$types;
    push @commands, { execute => 'quit' };
    my $input = join('', map { JSON->new->canonical->encode($_) . "\n" } @commands);

    my $res = {};
    my $code = sub {
        my $line = shift;
        my $msg = eval { decode_json($line) } or return;
        return if !defined($msg->{id}) || ref($msg->{return}) ne 'ARRAY';
        $res->{ $msg->{id} } =
            { map { $_->{name} => $_->{'default-value'} } $msg->{return}->@* };
    };

    PVE::Tools::run_command(
        [$binary, '-machine', 'none', '-nodefaults', '-display', 'none', '-qmp', 'stdio'],
        input => $input,
        outfunc => $code,
        timeout => 30,
    );

    return $res;
}

# Returns how the QEMU binary can IPL from devices of the given types: 'ccw' (a channel-program
# IPL from the device), 'firmware' (through the s390-ccw firmware, selected with bootindex) or
# 'none'. Device types without the 'iplable' property (QEMU without them) use the defaults above.
sub kvm_device_ipl_methods {
    my ($binary, $types) = @_;

    my $st = stat($binary) or die "unable to stat QEMU binary '$binary' - $!\n";
    if (($kvm_ipl_methods_mtime->{$binary} // -1) != $st->mtime) {
        $kvm_ipl_methods->{$binary} = {};
        $kvm_ipl_methods_mtime->{$binary} = $st->mtime;
    }
    my $methods = $kvm_ipl_methods->{$binary};

    my @missing = grep { !exists($methods->{$_}) } @$types;
    if (@missing) {
        my $properties = eval { query_device_type_properties($binary, \@missing) } // {};
        warn "unable to query the IPL capabilities of QEMU device types - $@" if $@;
        for my $type (@missing) {
            my $props = $properties->{$type};
            if ($props && exists($props->{iplable})) {
                $methods->{$type} = $props->{iplable} ? ($props->{'ipl-method'} // 'none') : 'none';
            } else {
                $methods->{$type} = $default_ipl_methods->{$type} // 'none';
            }
        }
    }

    return { map { $_ => $methods->{$_} } @$types };
}

# Paths and directories

# FIXME: MAJOR VERSION: use /run/qemu-server everywhere instead of mixing /run and /var/run and rely
# on debian/tmpfiles config to create the directory.
our $var_run_tmpdir = "/var/run/qemu-server";
mkdir $var_run_tmpdir;

sub qmp_socket {
    my ($peer) = @_;
    my ($id, $type) = $peer->@{qw(id type)};
    return "${var_run_tmpdir}/${id}.${type}";
}

sub qsd_pidfile_name {
    my ($id) = @_;
    return "${var_run_tmpdir}/qsd-${id}.pid";
}

sub qsd_fuse_export_cleanup_files {
    my ($id) = @_;

    # Usually, /var/run is a symlink to /run. It needs to be the exact path for checking if mounted
    # below. Note that Cwd::realpath() needs to be done on the directory already. Doing it on the
    # file does not work if the storage daemon is not running and the FUSE is still mounted.
    my ($real_dir) = Cwd::realpath($var_run_tmpdir) =~ m/^(.*)$/; # untaint
    if (!$real_dir) {
        warn "error resolving $var_run_tmpdir - not checking for left-over QSD files\n";
        return;
    }

    my $mounts = PVE::ProcFSTools::parse_proc_mounts();

    PVE::Tools::dir_glob_foreach(
        $real_dir,
        "qsd-${id}-.*\.fuse",
        sub {
            my ($file) = @_;
            my $path = "${real_dir}/${file}";
            if (grep { $_->[1] eq $path } $mounts->@*) {
                PVE::Tools::run_command(['umount', $path]);
            }
            unlink $path;
        },
    );
}

sub qsd_fuse_export_path {
    my ($id, $export_name) = @_;
    return "${var_run_tmpdir}/qsd-${id}-${export_name}.fuse";
}

sub vm_pidfile_name {
    my ($vmid) = @_;
    return "${var_run_tmpdir}/$vmid.pid";
}

# The consoles of an s390x VM depend on its OS type. Linux uses the VT220 SCLP console ('sclp'),
# where the firmware prints its messages too. Any other OS type gets the line-mode ('sclplm') and
# the integrated 3270 ('3270') SCLP consoles of the mainframe operating systems instead. The first
# one is the default console.
sub get_s390x_consoles {
    my ($conf) = @_;

    return is_linux_ostype($conf->{ostype}) ? ['sclp'] : ['sclplm', '3270'];
}

sub is_linux_ostype {
    my ($ostype) = @_;
    return ($ostype // 'other') =~ m/^l\d\d$/;
}

# The 3270 terminals ('terminalN') of an s390x VM, CCW devices that QEMU serves over TN3270 on a
# socket each.
our $MAX_TERMINALS = 16;

# The interfaces 'qm terminal' and termproxy can open: serial ports, the SCLP consoles of s390x
# VMs and their 3270 terminals.
sub terminal_ifaces {
    return [
        (map { "serial$_" } 0 .. 3),
        qw(sclp sclplm 3270),
        (map { "terminal$_" } 0 .. $MAX_TERMINALS - 1),
    ];
}

sub console_socket {
    my ($vmid, $console) = @_;
    return "${var_run_tmpdir}/${vmid}.$console";
}

# The command that attaches the terminal to the console or serial port $iface of a VM, $escape is
# the character code of the escape key (0 for none). $model is the 3270 model to emulate for a
# 3270 terminal, if configured.
sub get_terminal_command {
    my ($vmid, $iface, $escape, $model) = @_;

    my $socket = console_socket($vmid, $iface);

    if ($iface eq '3270' || $iface =~ m/^terminal\d+$/) {
        # c3270 talks TN3270 to the socket itself and has its own escape key (Ctrl+]). Without a
        # model, it emulates the largest 3270 model that fits the terminal (model 2 to 4).
        return ['c3270', (defined($model) ? ('-model', "3279-$model") : ()), "U:$socket"];
    }

    my $options = 'raw,echo=0';
    $options .= sprintf(',escape=0x%x', $escape) if $escape;
    return ['socat', "UNIX-CONNECT:$socket", "STDIO,$options"];
}

sub vnc_socket {
    my ($vmid) = @_;
    return "${var_run_tmpdir}/$vmid.vnc";
}

sub mtunnel_socket {
    my ($vmid) = @_;
    return "/run/qemu-server/$vmid.mtunnel";
}

# Parse the cmdline of a running kvm/qemu-* process and return arguments as hash
sub parse_cmdline {
    my ($pid) = @_;

    my $fh = IO::File->new("/proc/$pid/cmdline", "r");
    if (defined($fh)) {
        my $line = <$fh>;
        $fh->close;
        return if !$line;
        my @param = split(/\0/, $line);

        my $cmd = $param[0];
        return if !$cmd || ($cmd !~ m|kvm$| && $cmd !~ m@(?:^|/)qemu-[^/]+$@);

        my $phash = {};
        my $pending_cmd;
        for (my $i = 0; $i < scalar(@param); $i++) {
            my $p = $param[$i];
            next if !$p;

            if ($p =~ m/^--?(.*)$/) {
                if ($pending_cmd) {
                    $phash->{$pending_cmd} = {};
                }
                $pending_cmd = $1;
            } elsif ($pending_cmd) {
                $phash->{$pending_cmd} = { value => $p };
                $pending_cmd = undef;
            }
        }

        return $phash;
    }
    return;
}

my sub instance_running_locally {
    my ($pidfile) = @_;

    if (my $fd = IO::File->new("<$pidfile")) {
        my $st = stat($fd);
        my $line = <$fd>;
        close($fd);

        my $mtime = $st->mtime;
        if ($mtime > time()) {
            warn "file '$pidfile' modified in future\n";
        }

        if ($line =~ m/^(\d+)$/) {
            my $pid = $1;
            my $cmdline = parse_cmdline($pid);
            if (
                $cmdline
                && defined($cmdline->{pidfile})
                && $cmdline->{pidfile}->{value}
                && $cmdline->{pidfile}->{value} eq $pidfile
            ) {
                if (my $pinfo = PVE::ProcFSTools::check_process_running($pid)) {
                    return $pid;
                }
            }
        }
    }

    return;
}

sub qsd_running_locally {
    my ($id) = @_;

    my $pidfile = qsd_pidfile_name($id);

    return instance_running_locally($pidfile);
}

sub vm_running_locally {
    my ($vmid) = @_;

    my $pidfile = vm_pidfile_name($vmid);

    return instance_running_locally($pidfile);
}

# Parses a version string like X.Y.Z+pveW and returns (X, Y, Z, W) as numeric values. The micro and
# pve version are optional and will be undefined in the result if not specified in the version
# string.
sub version_parts {
    my ($verstr) = @_;

    if ($verstr =~ m/^(\d+)\.(\d+)(?:\.(\d+))?(?:\+pve(\d+))?/) {
        my $major = $1 + 0;
        my $minor = $2 + 0;
        my $patch = $3;
        $patch += 0 if defined($patch);
        my $pve = $4;
        $pve += 0 if defined($pve);
        return ($major, $minor, $patch, $pve);
    }

    return;
}

sub min_version {
    my ($verstr, $major, $minor, $pve) = @_;

    if (my ($got_major, $got_minor, $got_patch, $got_pve) = version_parts($verstr)) {
        return 1
            if PVE::Tools::version_cmp($got_major, $major, $got_minor, $minor, $got_pve, $pve) >= 0;
        return 0;
    }

    die "internal error: cannot check version of invalid string '$verstr'";
}

sub config_aware_timeout {
    my ($config, $memory, $is_suspended) = @_;
    my $timeout = 30;

    # Based on user reported startup time for vm with 512GiB @ 4-5 minutes
    if (defined($memory) && $memory > 30720) {
        $timeout = int($memory / 1024);
    }

    # When using PCI passthrough, users reported much higher startup times,
    # growing with the amount of memory configured. Constant factor chosen
    # based on user reports.
    if (grep(/^hostpci[0-9]+$/, keys %$config)) {
        $timeout *= 4;
    }

    if ($is_suspended && $timeout < 300) {
        $timeout = 300;
    }

    if ($config->{hugepages} && $timeout < 150) {
        $timeout = 150;
    }

    # Some testing showed that adding a NIC increased the start time by ~450ms
    # consistently across different NIC models, options and already existing
    # number of NICs.
    # So 10x that to account for any potential system differences seemed
    # reasonable. User reports with real-life values (20+: ~50s, 25: 45s, 17: 42s)
    # also make this seem a good value.
    my $nic_count = scalar(grep { /^net\d+/ } keys %{$config});
    $timeout += $nic_count * 5;

    return $timeout;
}

sub parse_number_sets {
    my ($set) = @_;
    my $res = [];
    foreach my $part (split(/;/, $set)) {
        if ($part =~ /^\s*(\d+)(?:-(\d+))?\s*$/) {
            die "invalid range: $part ($2 < $1)\n" if defined($2) && $2 < $1;
            push @$res, [$1, $2];
        } else {
            die "invalid range: $part\n";
        }
    }
    return $res;
}

sub windows_version {
    my ($ostype) = @_;

    return 0 if !$ostype;

    my $winversion = 0;

    if ($ostype eq 'wxp' || $ostype eq 'w2k3' || $ostype eq 'w2k') {
        $winversion = 5;
    } elsif ($ostype eq 'w2k8' || $ostype eq 'wvista') {
        $winversion = 6;
    } elsif ($ostype =~ m/^win(\d+)$/) {
        $winversion = $1;
    }

    return $winversion;
}

sub needs_extraction {
    my ($vtype, $fmt) = @_;
    return $vtype eq 'import' && $fmt =~ m/^ova\+(.*)$/;
}

sub get_iscsi_initiator_name {
    my $initiator;

    my $fh = IO::File->new('/etc/iscsi/initiatorname.iscsi') || return;
    while (defined(my $line = <$fh>)) {
        next if $line !~ m/^\s*InitiatorName\s*=\s*([\.\-:\w]+)/;
        $initiator = $1;
        last;
    }
    $fh->close();

    return $initiator;
}

my $_host_bits;

sub get_host_phys_address_bits {
    return $_host_bits if defined($_host_bits);

    my $fh = IO::File->new('/proc/cpuinfo', "r") or return;
    while (defined(my $line = <$fh>)) {
        # hopefully we never need to care about mixed (big.LITTLE) archs
        if ($line =~ m/^address sizes\s*:\s*(\d+)\s*bits physical/i) {
            $_host_bits = int($1);
            $fh->close();
            return $_host_bits;
        }
    }
    $fh->close();
    return; # undef, cannot really do anything..
}

1;
