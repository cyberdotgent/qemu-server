package PVE::QemuServer::SclpLog;

# The hardcopy of the SCLP line-mode console of s390x VMs.
#
# On a real machine the line-mode console (the "Operating System Messages" of the HMC) is a
# hardcopy device: every message of the operating system is a line on an endless roll of paper.
# QEMU (sclplmconsole property 'hardcopy') writes every message of the guest as a line to a file,
# whether or not a client is connected to the console, and a marker line for every IPL:
#
#   ──── IPL 0.0.0200 LOADPARM I at 2026-11-19 10:17:02 ────
#
# The file holds everything since the VM was started: a start moves the log of the previous run
# to <log>.1, resuming from a saved state (hibernation, snapshot with RAM) continues it, and a
# live migration within the cluster moves it to the target node before the VM resumes there.
# Operator commands are sent to the console socket of the VM, so they work without a viewer.

use strict;
use warnings;

use Encode qw(decode);
use Fcntl qw(O_WRONLY O_CREAT O_APPEND SEEK_SET);
use IO::Select;
use IO::Socket::UNIX;
use POSIX qw(strftime);
use Socket qw(SOCK_STREAM);

use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

our $LOG_DIR = '/var/log/qemu-server';

# the chardev of the console, see PVE::QemuServer::config_to_command()
my $CHARDEV = 'sclplm';

# QEMU passes at most this many bytes of a command to the guest (two one-byte-length GDS
# subvectors around it)
our $MAX_COMMAND_LENGTH = 251;

sub log_path {
    my ($vmid, $previous) = @_;
    return "$LOG_DIR/$vmid-sclplm.log" . ($previous ? '.1' : '');
}

# Whether the VM has a line-mode console, the one console with a hardcopy.
sub has_hardcopy {
    my ($conf) = @_;

    return 0 if PVE::QemuServer::Helpers::get_vm_arch($conf) ne 's390x';
    return (grep { $_ eq 'sclplm' } PVE::QemuServer::Helpers::get_s390x_consoles($conf)->@*)
        ? 1
        : 0;
}

# The QEMU options that add the hardcopy to the line-mode console: a chardev, and the property of
# the console device.
sub chardev_option {
    my ($vmid) = @_;
    return "file,id=$CHARDEV-hardcopy,path=" . log_path($vmid) . ",append=on";
}

sub device_property {
    return "hardcopy=$CHARDEV-hardcopy";
}

sub marker_line {
    my ($text) = @_;
    my $time = strftime('%Y-%m-%d %H:%M:%S', localtime());
    return "\x{2500}\x{2500}\x{2500}\x{2500} $text at $time \x{2500}\x{2500}\x{2500}\x{2500}\n";
}

# Append text (lines) to the log of a VM. QEMU has the file open for appending too, and writes
# whole lines: O_APPEND writes of a few lines do not interleave with them.
sub append_log {
    my ($vmid, $text) = @_;

    my $bytes = Encode::encode('UTF-8', $text);
    sysopen(my $fh, log_path($vmid), O_WRONLY | O_CREAT | O_APPEND, 0640)
        or die "unable to open the line-mode console log of VM $vmid - $!\n";
    my $written = syswrite($fh, $bytes);
    close($fh);
    die "unable to write the line-mode console log of VM $vmid - $!\n"
        if !defined($written) || $written != length($bytes);
}

my sub create_empty_log {
    my ($vmid) = @_;

    # created here, not by QEMU, to not make it world-readable (operator commands, passwords)
    sysopen(my $fh, log_path($vmid), O_WRONLY | O_CREAT | O_APPEND, 0640)
        or die "unable to create the line-mode console log of VM $vmid - $!\n";
    close($fh);
}

# Prepare the log for a start of the VM. A fresh start (also the target of a migration, which gets
# the log from the source) begins a new log and keeps the one of the previous run as <log>.1;
# resuming from a saved state continues the log.
sub prepare_start {
    my ($vmid, $resume_from_state) = @_;

    mkdir($LOG_DIR, 0755) if !-d $LOG_DIR;

    if ($resume_from_state && -e log_path($vmid)) {
        append_log($vmid, marker_line("VM resumed from a saved state"));
        return;
    }
    if (-e log_path($vmid)) {
        rename(log_path($vmid), log_path($vmid, 1))
            or warn "unable to keep the previous line-mode console log of VM $vmid - $!\n";
    }
    create_empty_log($vmid);
}

sub remove_logs {
    my ($vmid) = @_;
    unlink(log_path($vmid), log_path($vmid, 1));
}

# Read the log. Returns { id, size, start, end, data, complete }: 'id' changes when a new log
# starts (a start of the VM), 'data' holds the whole lines from byte offset 'start' to 'end'.
# Without $start, the last $tail bytes (from the next line start on).
sub read_log {
    my ($vmid, $start, $tail, $max, $previous) = @_;

    $max //= 1024 * 1024;
    my $path = log_path($vmid, $previous);

    my $res = { id => '', size => 0, start => 0, end => 0, data => '', complete => 1 };
    open(my $fh, '<:raw', $path) or return $res;
    my @st = stat($fh);
    my $size = $st[7];
    $res->{id} = "$st[0]:$st[1]:$st[9]";
    $res->{size} = $size;

    my $skip_partial = 0;
    if (defined($start)) {
        $start = $size if $start > $size;
    } else {
        $tail //= 64 * 1024;
        $start = $size > $tail ? $size - $tail : 0;
        $skip_partial = $start > 0;
    }

    my $bytes = '';
    if ($start < $size) {
        sysseek($fh, $start, SEEK_SET) or die "unable to seek in '$path' - $!\n";
        my $want = $size - $start;
        $want = $max if $want > $max;
        while (length($bytes) < $want) {
            my $n = sysread($fh, $bytes, $want - length($bytes), length($bytes));
            die "unable to read '$path' - $!\n" if !defined($n);
            last if !$n;
        }
    }
    close($fh);

    if ($skip_partial) {
        my $nl = index($bytes, "\n");
        if ($nl >= 0) {
            $start += $nl + 1;
            $bytes = substr($bytes, $nl + 1);
        }
    }
    # whole lines only, unless a single line does not fit
    my $last_nl = rindex($bytes, "\n");
    if ($last_nl >= 0) {
        $bytes = substr($bytes, 0, $last_nl + 1);
    } elsif (length($bytes) < $max) {
        $bytes = '';
    }

    $res->{start} = $start;
    $res->{end} = $start + length($bytes);
    $res->{data} = decode('UTF-8', $bytes); # replaces malformed sequences
    $res->{complete} = $res->{end} >= $size ? 1 : 0;
    return $res;
}

sub check_command {
    my ($command) = @_;

    die "the command contains control characters\n" if $command =~ m/[\x00-\x1f\x7f-\x9f]/;
    die "the command is longer than $MAX_COMMAND_LENGTH characters\n"
        if length($command) > $MAX_COMMAND_LENGTH;
    die "empty command\n" if $command !~ m/\S/;
}

# Whether a client is connected to the console socket of a running VM (QEMU serves one at a time).
sub console_in_use {
    my ($vmid) = @_;

    my $chardevs = mon_cmd($vmid, 'query-chardev');
    for my $chardev ($chardevs->@*) {
        next if $chardev->{label} ne $CHARDEV;
        return $chardev->{filename} !~ m/^disconnected:/ ? 1 : 0;
    }
    return 0;
}

# Send an operator command to the line-mode console of a running VM, as if it was entered there.
# QEMU's line editor passes it to the guest as one line, or queues it while the guest has not read
# the previous one.
sub send_command {
    my ($vmid, $command) = @_;

    check_command($command);

    my $socket = PVE::QemuServer::Helpers::console_socket($vmid, $CHARDEV);
    die "VM $vmid has no line-mode console\n" if !-S $socket;
    die "the line-mode console of VM $vmid is in use by a terminal ('qm terminal $vmid"
        . " --iface sclplm'), close it to send commands here\n"
        if console_in_use($vmid);

    my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket, Timeout => 5)
        or die "unable to connect to the line-mode console of VM $vmid - $!\n";
    binmode($sock);

    # Ctrl+U clears whatever a previous client left in the line editor, CR enters the line
    my $bytes = "\x15" . Encode::encode('UTF-8', $command) . "\r";
    while (length($bytes)) {
        my $n = syswrite($sock, $bytes);
        die "unable to write to the line-mode console of VM $vmid - $!\n" if !defined($n);
        substr($bytes, 0, $n, '');
    }

    # wait for the line editor to finish the line (its echo ends with a line end), so the
    # command is handed over before the connection goes away
    my $select = IO::Select->new($sock);
    my $echo = '';
    my $deadline = time() + 3;
    while ($echo !~ m/\n/ && time() <= $deadline) {
        last if !$select->can_read(0.5);
        my $n = sysread($sock, $echo, 4096, length($echo));
        last if !$n;
    }
    close($sock);

    die "the line-mode console of VM $vmid did not take the command\n" if $echo !~ m/\n/;
    return;
}

1;
