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
# The host adds the operator commands it passes to the console, as input lines with the user:
#
#   ▶▶▶▶ root@pam 2026-11-20 10:15:03: d a,l
#
# Neither marker can come from the guest: its messages are EBCDIC converted to ISO 8859-1, and
# '─' (U+2500) and '▶' (U+25B6) are not in ISO 8859-1.
#
# Files: <vmid>-sclplm.log is the current log, <vmid>-sclplm.log.<n> the older generations, .1
# the newest. A file is rotated at $ROTATE_SIZE, a start of the VM begins a new file too, and the
# oldest generations are removed so that all files of a VM stay within $MAX_TOTAL_SIZE. A new file
# begins with a marker line naming the file before it. Resuming from a saved state (hibernation,
# snapshot with RAM) continues the log, a live migration within the cluster moves it to the target
# node before the VM resumes there.
#
# The unit pve-qemu-sclplm@<vmid>.service (run_daemon()) rotates the log while the VM runs, and
# forwards it to a syslog server if the VM has 'sclplm-syslog' set. QEMU only writes the file: a
# slow or unreachable syslog server cannot hold up the guest's console.

use strict;
use warnings;

use Digest::MD5 qw(md5_hex);
use File::Copy;
use JSON;
use Encode qw(decode encode);
use Errno qw(EAGAIN EINPROGRESS EINTR EWOULDBLOCK EISCONN);
use Fcntl qw(:flock O_WRONLY O_CREAT O_APPEND SEEK_SET);
use IO::Select;
use IO::Socket::IP;
use IO::Socket::UNIX;
use POSIX qw(strftime);
use Socket qw(SOCK_STREAM SOCK_DGRAM SOL_SOCKET SO_ERROR);
use Time::HiRes qw(time);

use PVE::JSONSchema;
use PVE::Tools qw(run_command);

use PVE::QemuServer::Helpers;
use PVE::QemuServer::Monitor qw(mon_cmd);

our $LOG_DIR = '/var/log/qemu-server';
our $ROTATE_SIZE = 64 * 1024 * 1024;
our $MAX_TOTAL_SIZE = 512 * 1024 * 1024;

# the chardevs of the console, see PVE::QemuServer::config_to_command()
my $CHARDEV = 'sclplm';
my $HARDCOPY_CHARDEV = 'sclplm-hardcopy';

# QEMU passes at most this many bytes of a command to the guest (two one-byte-length GDS
# subvectors around it)
our $MAX_COMMAND_LENGTH = 251;

our $INPUT_MARK = "\x{25b6}" x 4;
our $HOST_MARK = "\x{2500}" x 4;

my $facilities = {
    kern => 0, user => 1, mail => 2, daemon => 3, auth => 4, syslog => 5, lpr => 6, news => 7,
    uucp => 8, cron => 9, authpriv => 10, ftp => 11,
    map { ("local$_" => 16 + $_) } 0 .. 7,
};

my $syslog_fmt = {
    proto => {
        type => 'string',
        enum => ['udp', 'tcp'],
        default => 'udp',
        description => "Transport: UDP (RFC 5426) or TCP (octet-counted, RFC 6587).",
        optional => 1,
    },
    host => {
        type => 'string',
        format => 'address',
        format_description => 'address',
        default_key => 1,
        description => "Syslog server: DNS name, IPv4 or IPv6 address.",
    },
    port => {
        type => 'integer',
        minimum => 1,
        maximum => 65535,
        default => 514,
        optional => 1,
    },
    facility => {
        type => 'string',
        enum => [sort { $facilities->{$a} <=> $facilities->{$b} } keys %$facilities],
        default => 'local0',
        description => "Syslog facility of the messages.",
        optional => 1,
    },
};
PVE::JSONSchema::register_format('pve-qm-sclplm-syslog', $syslog_fmt);

our $syslog_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-sclplm-syslog',
    description => "Forward the SCLP line-mode console of an s390x VM to a syslog server: the"
        . " messages of the guest, the operator commands passed to the console and the IPL"
        . " markers, as RFC 5424 messages (MSGID OUT, IN, MARK). Applies while the VM runs.",
};

sub parse_syslog {
    my ($value) = @_;

    return undef if !defined($value) || !length($value);
    my $res = PVE::JSONSchema::parse_property_string($syslog_fmt, $value);
    $res->{proto} //= 'udp';
    $res->{port} //= 514;
    $res->{facility} //= 'local0';
    return $res;
}

sub log_path {
    my ($vmid, $generation) = @_;
    return "$LOG_DIR/$vmid-sclplm.log" . ($generation ? ".$generation" : '');
}

sub log_name {
    my ($vmid, $generation) = @_;
    return "$vmid-sclplm.log" . ($generation ? ".$generation" : '');
}

my sub lock_file {
    my ($vmid) = @_;
    return "${PVE::QemuServer::Helpers::var_run_tmpdir}/$vmid.sclplm.lock";
}

sub state_file {
    my ($vmid) = @_;
    return "${PVE::QemuServer::Helpers::var_run_tmpdir}/$vmid.sclplm.fwd";
}

# Run $code with the lock of the log files of the VM (rotation, start, migration).
sub lock_logs {
    my ($vmid, $code) = @_;

    open(my $fh, '>>', lock_file($vmid)) or die "unable to open lock file - $!\n";
    flock($fh, LOCK_EX) or die "unable to lock the line-mode console log of VM $vmid - $!\n";
    my $res = eval { $code->() };
    my $err = $@;
    close($fh);
    die $err if $err;
    return $res;
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
    return "file,id=$HARDCOPY_CHARDEV,path=" . log_path($vmid) . ",append=on";
}

sub device_property {
    return "hardcopy=$HARDCOPY_CHARDEV";
}

sub timestamp {
    my ($t) = @_;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($t // time()));
}

sub marker_line {
    my ($text) = @_;
    return "$HOST_MARK $text at " . timestamp() . " $HOST_MARK\n";
}

sub input_line {
    my ($user, $command, $via) = @_;
    my $who = $user . ($via ? " ($via)" : '');
    return "$INPUT_MARK $who " . timestamp() . ": $command\n";
}

# Append text (lines) to the log of a VM. QEMU has the file open for appending too, and writes
# whole lines: O_APPEND writes of a few lines do not interleave with them.
sub append_log {
    my ($vmid, $text) = @_;

    my $bytes = encode('UTF-8', $text);
    sysopen(my $fh, log_path($vmid), O_WRONLY | O_CREAT | O_APPEND, 0640)
        or die "unable to open the line-mode console log of VM $vmid - $!\n";
    my $written = syswrite($fh, $bytes);
    close($fh);
    die "unable to write the line-mode console log of VM $vmid - $!\n"
        if !defined($written) || $written != length($bytes);
}

# The generations (numbers) of older log files of a VM, newest (1) first.
sub generations {
    my ($vmid) = @_;

    my @gens;
    opendir(my $dh, $LOG_DIR) or return [];
    while (defined(my $name = readdir($dh))) {
        push @gens, $1 if $name =~ m/^\Q$vmid\E-sclplm\.log\.([1-9]\d*)$/;
    }
    closedir($dh);
    return [sort { $a <=> $b } @gens];
}

# Remove the oldest generations until all files of the VM, with $reserve bytes for the current
# one to grow, stay within $MAX_TOTAL_SIZE. The current file and generation 1 always stay.
my sub enforce_total_size {
    my ($vmid, $reserve) = @_;

    my $gens = generations($vmid);
    my $total = $reserve;
    $total += (-s log_path($vmid, $_)) // 0 for @$gens;
    while (scalar(@$gens) > 1 && $total > $MAX_TOTAL_SIZE) {
        my $oldest = pop @$gens;
        my $path = log_path($vmid, $oldest);
        $total -= (-s $path) // 0;
        unlink($path) or warn "unable to remove '$path' - $!\n";
    }
}

# Shift the generations up by one and make the current file generation 1. Under lock_logs().
my sub shift_generations {
    my ($vmid) = @_;

    for my $gen (reverse generations($vmid)->@*) {
        rename(log_path($vmid, $gen), log_path($vmid, $gen + 1))
            or die "unable to rename '" . log_path($vmid, $gen) . "' - $!\n";
    }
    if (-e log_path($vmid)) {
        rename(log_path($vmid), log_path($vmid, 1))
            or die "unable to rename '" . log_path($vmid) . "' - $!\n";
    }
    enforce_total_size($vmid, $ROTATE_SIZE);
}

my sub create_log {
    my ($vmid, $first_line) = @_;

    # created here, not by QEMU, to not make it world-readable (operator commands, passwords)
    sysopen(my $fh, log_path($vmid), O_WRONLY | O_CREAT | O_APPEND, 0640)
        or die "unable to create the line-mode console log of VM $vmid - $!\n";
    syswrite($fh, encode('UTF-8', $first_line)) if defined($first_line);
    close($fh);
}

# Prepare the log for a start of the VM, $how:
#   'start'  - a fresh start (also the target of a migration, which gets the log from the source):
#              a new file, the previous one becomes generation 1
#   'resume' - resuming from a saved state (hibernation, rollback of a snapshot with RAM): the log
#              continues, with one marker line
#   'backup' - the paused start of a stopped VM for a backup, which does not run the guest: the
#              log continues, without a marker (QEMU writes the IPL marker only if the guest runs)
# The position of the forwarder (state_file()) is kept when the log continues, so the syslog
# server does not get the log again.
sub prepare_start {
    my ($vmid, $how) = @_;

    $how //= 'start';
    die "unknown start type '$how'\n" if $how !~ m/^(?:start|resume|backup)$/;

    mkdir($LOG_DIR, 0755) if !-d $LOG_DIR;

    lock_logs(
        $vmid,
        sub {
            if ($how ne 'start' && -e log_path($vmid)) {
                append_log($vmid, marker_line("VM resumed from a saved state"))
                    if $how eq 'resume';
                return;
            }
            unlink(state_file($vmid));
            my $had_log = -s log_path($vmid);
            shift_generations($vmid) if -e log_path($vmid);
            create_log(
                $vmid,
                $had_log
                    ? marker_line("VM $vmid started, the previous log is " . log_name($vmid, 1))
                    : undef,
            );
        },
    );
}

# The guest of a VM started paused for a backup is started (in the QEMU of the backup): mark the
# start in the log, which continued without a marker (see prepare_start()). QEMU adds the IPL marker
# when the guest runs.
sub backup_vm_started {
    my ($vmid, $conf) = @_;

    eval {
        return if !has_hardcopy($conf) || !-e log_path($vmid);
        my $status = mon_cmd($vmid, 'query-status');
        return if ($status->{status} // '') ne 'prelaunch';
        append_log($vmid, marker_line("VM $vmid started during a backup"));
    };
    warn $@ if $@;
}

# Remove the log files of a VM (destroy). Also stops the unit that follows them.
sub remove_logs {
    my ($vmid) = @_;

    stop_unit($vmid);
    unlink(log_path($vmid), map { log_path($vmid, $_) } generations($vmid)->@*);
    unlink(state_file($vmid));
    unlink(lock_file($vmid));
}

# Identifies a log file for readers that follow it: its inode and its first line (a new file at a
# start, after a rotation or a migration gets another one; the first line has a timestamp).
my sub file_id {
    my ($fh, @st) = @_;

    my $first = '';
    sysseek($fh, 0, SEEK_SET);
    sysread($fh, $first, 256);
    my $nl = index($first, "\n");
    $first = $nl >= 0 ? substr($first, 0, $nl) : '';
    return "$st[0]:$st[1]:" . substr(md5_hex($first), 0, 12);
}

# Size and modification time of the log files of a VM: [{ generation, name, size, mtime }],
# the current file (generation 0) first.
sub list_files {
    my ($vmid) = @_;

    my $res = [];
    for my $gen (0, generations($vmid)->@*) {
        my @st = stat(log_path($vmid, $gen)) or next;
        push @$res,
            { generation => $gen, name => log_name($vmid, $gen), size => $st[7], mtime => $st[9] };
    }
    return $res;
}

# Read a log file. Returns { id, size, start, end, data, complete }: 'id' changes when it is
# another file (a start, a rotation), 'data' holds the whole lines from byte offset 'start' to
# 'end'. Without $start, the last $tail bytes (from the next line start on).
sub read_log {
    my ($vmid, $start, $tail, $max, $generation) = @_;

    $max //= 1024 * 1024;
    my $path = log_path($vmid, $generation);

    my $res = { id => '', size => 0, start => 0, end => 0, data => '', complete => 1 };
    open(my $fh, '<:raw', $path) or return $res;
    my @st = stat($fh);
    my $size = $st[7];
    $res->{id} = file_id($fh, @st);
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

# Rotate the current log of a running VM: it becomes generation 1, a new file with a marker line
# is the current one, and QEMU is switched to it (QMP chardev-change, nothing is lost). A QEMU
# that cannot switch the hardcopy keeps writing the file it has open: then the file is copied to
# generation 1 and truncated instead, which loses the lines QEMU writes in between.
sub rotate {
    my ($vmid) = @_;

    return lock_logs(
        $vmid,
        sub {
            my $path = log_path($vmid);
            return 0 if !-e $path;
            shift_generations($vmid);
            my $marker = marker_line("log continued from " . log_name($vmid, 1));
            create_log($vmid, $marker);
            eval {
                mon_cmd(
                    $vmid, 'chardev-change',
                    id => $HARDCOPY_CHARDEV,
                    backend => { type => 'file', data => { out => $path, append => JSON::true } },
                );
            };
            return 1 if !$@;
            warn "switching the hardcopy of VM $vmid to a new file failed, copying and"
                . " truncating instead - $@";

            # QEMU keeps writing the file it has open, now generation 1: make it the current file
            # again, and generation 1 a copy of it
            my $gen1 = log_path($vmid, 1);
            unlink($path);
            rename($gen1, $path) or die "unable to rename '$gen1' - $!
";
            File::Copy::copy($path, $gen1) or die "unable to copy '$path' - $!
";
            chmod(0640, $gen1);
            truncate($path, 0) or die "unable to truncate '$path' - $!
";
            append_log($vmid, $marker);
            return 1;
        },
    );
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

# Send an operator command to the line-mode console of a running VM, as if it was entered there,
# and log it as input of $user. QEMU's line editor passes it to the guest as one line, or queues it
# while the guest has not read the previous one.
sub send_command {
    my ($vmid, $command, $user) = @_;

    check_command($command);

    my $socket = PVE::QemuServer::Helpers::console_socket($vmid, $CHARDEV);
    die "VM $vmid has no line-mode console\n" if !-S $socket;
    die "the line-mode console of VM $vmid is in use by a terminal ('qm terminal $vmid"
        . " --iface sclplm'), close it to send commands here\n"
        if console_in_use($vmid);

    my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket, Timeout => 5)
        or die "unable to connect to the line-mode console of VM $vmid - $!\n";
    binmode($sock);

    # logged before it is sent, so it comes before what the guest answers
    eval { append_log($vmid, input_line($user // 'unknown', $command)) };
    warn $@ if $@;

    # Ctrl+U clears whatever a previous client left in the line editor, CR enters the line
    my $bytes = "\x15" . encode('UTF-8', $command) . "\r";
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

# Follows QEMU's line editor in the output of the console: what the operator typed is in the line
# that is finished when they press Enter, after their edits (the editor redraws the line with
# cursor movements and erase-to-end-of-line).
sub new_line_tracker {
    return { line => [], cursor => 0, esc => '' };
}

# Feed console output; returns the lines finished by it.
sub track_output {
    my ($t, $text) = @_;

    my @done;
    for my $c (split(//, $text)) {
        if (length($t->{esc})) {
            $t->{esc} .= $c;
            if ($t->{esc} =~ m/^\e\[([0-9;]*)([A-Za-z~])$/) {
                my ($n, $cmd) = (($1 eq '' ? 1 : $1), $2);
                if ($cmd eq 'D') {
                    $t->{cursor} -= $n;
                    $t->{cursor} = 0 if $t->{cursor} < 0;
                } elsif ($cmd eq 'C') {
                    $t->{cursor} += $n;
                } elsif ($cmd eq 'K') {
                    splice($t->{line}->@*, $t->{cursor}) if $t->{cursor} < scalar($t->{line}->@*);
                }
                $t->{esc} = '';
            } elsif ($t->{esc} !~ m/^\e(?:\[[0-9;]*)?$/) {
                $t->{esc} = ''; # unknown sequence
            }
        } elsif ($c eq "\e") {
            $t->{esc} = $c;
        } elsif ($c eq "\n") {
            push @done, join('', $t->{line}->@*);
            $t->{line} = [];
            $t->{cursor} = 0;
        } elsif ($c eq "\r") {
            $t->{cursor} = 0;
        } elsif ($c eq "\b") {
            $t->{cursor}-- if $t->{cursor} > 0;
        } elsif (ord($c) >= 0x20) {
            $t->{line}->[$t->{cursor}++] = $c;
            $t->{line}->[$_] //= ' ' for 0 .. $t->{cursor} - 1;
        }
    }
    return @done;
}

# 'qm terminal --iface sclplm': connect the terminal to the console and log the commands entered
# as input of $user. Each line starts in column 1 (LF to CR LF). The escape character exits.
sub terminal {
    my ($vmid, $escape, $user) = @_;

    my $socket = PVE::QemuServer::Helpers::console_socket($vmid, $CHARDEV);
    my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket)
        or die "unable to connect to the line-mode console of VM $vmid - $!\n";
    binmode($sock);
    binmode(STDIN);
    binmode(STDOUT);

    my $termios;
    if (-t STDIN) {
        $termios = POSIX::Termios->new();
        $termios->getattr(0);
        my $raw = POSIX::Termios->new();
        $raw->getattr(0);
        $raw->setlflag($raw->getlflag() & ~(POSIX::ECHO() | POSIX::ICANON() | POSIX::ISIG()
            | POSIX::IEXTEN()));
        $raw->setiflag($raw->getiflag() & ~(POSIX::ICRNL() | POSIX::IXON() | POSIX::INLCR()
            | POSIX::ISTRIP() | POSIX::BRKINT()));
        $raw->setcc(POSIX::VMIN(), 1);
        $raw->setcc(POSIX::VTIME(), 0);
        $raw->setattr(0, POSIX::TCSANOW());
    }
    my $restore = sub { $termios->setattr(0, POSIX::TCSANOW()) if $termios };

    my $tracker = new_line_tracker();
    my $entered = 0;
    my $utf8 = '';
    my $select = IO::Select->new(\*STDIN, $sock);
    eval {
        LOOP: while (1) {
            for my $fh ($select->can_read()) {
                my $buf = '';
                my $n = sysread($fh, $buf, 4096);
                next if !defined($n) && $! == EINTR;
                last LOOP if !$n;
                if ($fh == $sock) {
                    my $out = $buf =~ s/\n/\r\n/gr;
                    syswrite(STDOUT, $out);
                    $utf8 .= $buf;
                    my $text = decode('UTF-8', $utf8, Encode::FB_QUIET);
                    for my $line (track_output($tracker, $text)) {
                        next if !$entered;
                        $entered = 0;
                        eval { append_log($vmid, input_line($user, $line, 'terminal')) }
                            if $line =~ m/\S/;
                    }
                } else {
                    if ($escape && index($buf, chr($escape)) >= 0) {
                        $buf = substr($buf, 0, index($buf, chr($escape)));
                        syswrite($sock, $buf) if length($buf);
                        last LOOP;
                    }
                    $entered = 1 if $buf =~ m/[\r\n]/;
                    syswrite($sock, $buf);
                }
            }
        }
    };
    my $err = $@;
    $restore->();
    close($sock);
    die $err if $err;
}

# Forwarding to syslog

# The RFC 5424 message of a log line. The host is the VM (its name), the app 'pve-sclplm', the
# process the VMID; MSGID OUT for messages of the guest, IN for operator commands, MARK for the
# markers of the host (IPL, start, rotation, migration).
sub syslog_message {
    my ($cfg, $vmid, $vmname, $line, $time) = @_;

    my ($msgid, $severity) = ('OUT', 6); # informational
    my $msg = $line;
    if ($line =~ m/^\Q$INPUT_MARK\E (\S+(?: \(\w+\))?) \d{4}-\d\d-\d\d \d\d:\d\d:\d\d: (.*)$/) {
        ($msgid, $severity, $msg) = ('IN', 5, "$1: $2"); # notice
    } elsif ($line =~ m/^\Q$HOST_MARK\E /) {
        ($msgid, $severity) = ('MARK', 5);
    }
    my $pri = $facilities->{ $cfg->{facility} // 'local0' } * 8 + $severity;
    my $host = defined($vmname) && $vmname =~ m/^[!-~]{1,255}$/ ? $vmname : "vm$vmid";
    my @t = localtime($time);
    my $tz = strftime('%z', @t);
    $tz =~ s/^([+-]\d\d)(\d\d)$/$1:$2/;
    my $stamp = strftime('%Y-%m-%dT%H:%M:%S', @t)
        . sprintf('.%06d', ($time - int($time)) * 1_000_000) . $tz;
    return encode('UTF-8', "<$pri>1 $stamp $host pve-sclplm $vmid $msgid - $msg");
}

# A sender to a syslog server that never blocks: UDP datagrams are fire and forget, TCP messages
# wait in a bounded queue while the connection is (re)established; when the queue is full the
# oldest are dropped and counted.
sub new_sender {
    my ($cfg) = @_;
    return {
        cfg => $cfg,
        queue => [],
        queued_bytes => 0,
        dropped => 0,
        sock => undef,
        connecting => 0,
        next_attempt => 0,
        backoff => 1,
        partial => '',
        max_bytes => 4 * 1024 * 1024,
        max_messages => 20000,
    };
}

sub sender_close {
    my ($s) = @_;
    close($s->{sock}) if $s->{sock};
    $s->{sock} = undef;
    $s->{connecting} = 0;
    $s->{partial} = '';
}

# The connection broke: send the message being sent again on the next one, from its beginning.
sub sender_reconnect_later {
    my ($s) = @_;

    if (length($s->{partial}) && defined($s->{current})) {
        unshift $s->{queue}->@*, $s->{current};
        $s->{queued_bytes} += length($s->{current});
    }
    $s->{current} = undef;
    sender_close($s);
    $s->{next_attempt} = time() + $s->{backoff};
    $s->{backoff} = $s->{backoff} * 2 > 30 ? 30 : $s->{backoff} * 2;
}

my sub sender_connect {
    my ($s) = @_;

    my $cfg = $s->{cfg};
    my $udp = $cfg->{proto} eq 'udp';
    my $sock = IO::Socket::IP->new(
        PeerHost => $cfg->{host},
        PeerPort => $cfg->{port},
        Type => $udp ? SOCK_DGRAM : SOCK_STREAM,
        Blocking => 0,
    );
    if (!$sock) {
        warn "syslog server $cfg->{host} port $cfg->{port}: $@\n" if !$s->{warned}++;
        $s->{next_attempt} = time() + $s->{backoff};
        $s->{backoff} = $s->{backoff} * 2 > 30 ? 30 : $s->{backoff} * 2;
        return;
    }
    $s->{sock} = $sock;
    $s->{connecting} = !$udp && !$sock->connected;
    $s->{connected_at} = time() if !$s->{connecting};
}

# Queue a message (bytes).
sub sender_send {
    my ($s, $msg) = @_;

    if ($s->{cfg}->{proto} eq 'udp') {
        sender_connect($s) if !$s->{sock} && time() >= $s->{next_attempt};
        # RFC 5426: receivers should take 2048 bytes
        send($s->{sock}, substr($msg, 0, 2048), 0) if $s->{sock};
        # re-resolve the name now and then
        sender_close($s) if $s->{sock} && time() - ($s->{connected_at} // 0) > 300;
        return;
    }
    my $framed = length($msg) . " $msg"; # octet counting, RFC 6587
    push $s->{queue}->@*, $framed;
    $s->{queued_bytes} += length($framed);
    while (
        scalar($s->{queue}->@*) > 1
        && ($s->{queued_bytes} > $s->{max_bytes}
            || scalar($s->{queue}->@*) > $s->{max_messages})
    ) {
        my $old = shift $s->{queue}->@*;
        $s->{queued_bytes} -= length($old);
        $s->{dropped}++;
    }
}

# Make progress: connect, send what is queued, as far as possible without blocking. Returns the
# socket to wait for writability on, if any.
sub sender_pump {
    my ($s, $notice) = @_;

    return undef if $s->{cfg}->{proto} eq 'udp';
    if (!$s->{sock}) {
        return undef if time() < $s->{next_attempt};
        sender_connect($s);
        return undef if !$s->{sock};
    }
    my $sock = $s->{sock};
    if ($s->{connecting}) {
        if (!$sock->connect() && $! != EISCONN) {
            return $sock if $! == EINPROGRESS || $! == EAGAIN || $! == EWOULDBLOCK;
            warn "syslog server $s->{cfg}->{host} port $s->{cfg}->{port}: $!\n"
                if !$s->{warned}++;
            sender_close($s);
            $s->{next_attempt} = time() + $s->{backoff};
            $s->{backoff} = $s->{backoff} * 2 > 30 ? 30 : $s->{backoff} * 2;
            return undef;
        }
        $s->{connecting} = 0;
        $s->{backoff} = 1;
        $s->{warned} = 0;
        if ($s->{dropped}) {
            unshift $s->{queue}->@*, do {
                my $m = $notice->("$s->{dropped} messages dropped, the syslog server was not"
                    . " reachable");
                length($m) . " $m";
            };
            $s->{dropped} = 0;
        }
    }
    return undef if !length($s->{partial}) && !$s->{queue}->@*;

    # A server that closed the connection (or a reset) makes the socket readable: notice it before
    # writing, the kernel would take the next message and lose it.
    if (IO::Select->new($sock)->can_read(0)) {
        my $buf;
        my $n = sysread($sock, $buf, 4096); # a syslog server sends nothing, data is ignored
        if (defined($n) ? $n == 0 : ($! != EAGAIN && $! != EWOULDBLOCK)) {
            sender_reconnect_later($s);
            return undef;
        }
    }
    while (length($s->{partial}) || $s->{queue}->@*) {
        if (!length($s->{partial})) {
            $s->{current} = shift $s->{queue}->@*;
            $s->{queued_bytes} -= length($s->{current});
            $s->{partial} = $s->{current};
        }
        my $n = syswrite($sock, $s->{partial});
        if (!defined($n)) {
            return $sock if $! == EAGAIN || $! == EWOULDBLOCK;
            sender_reconnect_later($s);
            return undef;
        }
        substr($s->{partial}, 0, $n, '');
    }
    return undef;
}

# The unit that rotates and forwards the log of a running VM.

sub unit_name {
    my ($vmid) = @_;
    return "pve-qemu-sclplm\@$vmid.service";
}

sub start_unit {
    my ($vmid) = @_;
    eval { run_command(['/bin/systemctl', 'start', '--no-block', unit_name($vmid)]) };
    warn "failed to start the line-mode console log unit of VM $vmid - $@" if $@;
}

sub stop_unit {
    my ($vmid) = @_;
    eval { run_command(['/bin/systemctl', 'stop', unit_name($vmid)], quiet => 1, noerr => 1) };
}

# The main loop of pve-qemu-sclplm@<vmid>.service: follow the current log file (also across
# rotations), rotate it at $ROTATE_SIZE, forward its lines to the syslog server of the VM's config
# (re-read while running). Never touches QEMU's console: it only reads the file QEMU writes.
sub run_daemon {
    my ($vmid, %opts) = @_;

    my $load_conf = $opts{load_conf} // sub { PVE::QemuConfig->load_config($vmid) };
    my $running = $opts{running} // sub { PVE::QemuServer::Helpers::vm_running_locally($vmid) };
    my $interval = $opts{interval} // 0.5;

    my $path = log_path($vmid);
    my ($fh, $ino, $offset) = (undef, undef, 0);
    if (open(my $st, '<', state_file($vmid))) {
        my $line = <$st> // '';
        ($ino, $offset) = $line =~ m/^(\d+) (\d+)$/;
        close($st);
    }
    my ($conf, $cfg, $sender, $vmname);
    my $last_conf_check = 0;
    my $last_state = '';
    my $carry = '';

    my $notice = sub {
        my ($text) = @_;
        return syslog_message($cfg, $vmid, $vmname, "$HOST_MARK $text $HOST_MARK", time());
    };

    while (1) {
        my $now = time();
        if ($now - $last_conf_check >= 5) {
            $last_conf_check = $now;
            $conf = eval { $load_conf->() };
            if ($conf) {
                $vmname = $conf->{name};
                my $new = eval { parse_syslog($conf->{'sclplm-syslog'}) };
                warn "invalid sclplm-syslog option - $@" if $@;
                my $key = $new ? join(',', map { $new->{$_} } qw(proto host port facility)) : '';
                my $old = $cfg ? join(',', map { $cfg->{$_} } qw(proto host port facility)) : '';
                if ($key ne $old) {
                    sender_close($sender) if $sender;
                    $sender = $new ? new_sender($new) : undef;
                    $cfg = $new;
                    print "forwarding to syslog: " . ($key || 'off') . "\n";
                }
            }
        }

        # the current file, or a new one after a rotation (finish the old one first)
        my @st = stat($path);
        if (!$fh || (@st && $st[1] != $ino)) {
            if ($fh) {
                # read the rest of the rotated file below, then switch
            } elsif (@st) {
                open($fh, '<:raw', $path) or die "unable to open '$path' - $!\n";
                $offset = 0 if !defined($ino) || $st[1] != $ino || $offset > $st[7];
                $ino = $st[1];
                sysseek($fh, $offset, SEEK_SET);
            }
        }
        if ($fh) {
            my $buf = '';
            while (1) {
                my $n = sysread($fh, $buf, 65536, length($buf));
                last if !$n;
            }
            $offset += length($buf);
            if (length($buf)) {
                $carry .= $buf;
                my $last_nl = rindex($carry, "\n");
                if ($last_nl >= 0) {
                    my $lines = substr($carry, 0, $last_nl);
                    $carry = substr($carry, $last_nl + 1);
                    if ($sender) {
                        for my $line (split(/\n/, decode('UTF-8', $lines), -1)) {
                            sender_send($sender, syslog_message($cfg, $vmid, $vmname, $line, $now));
                        }
                    }
                }
            }
            my @cur = stat($path);
            if (@cur && $cur[1] != $ino) {
                # rotated: everything of the old file has been read, go on with the new one
                close($fh);
                $fh = undef;
                $carry = '';
                $ino = $cur[1];
                $offset = 0;
                open($fh, '<:raw', $path) or die "unable to open '$path' - $!\n";
                next;
            } elsif (@cur && $cur[7] < $offset) {
                # truncated (copy and truncate rotation)
                sysseek($fh, 0, SEEK_SET);
                $offset = 0;
                $carry = '';
            }
            if (@cur && $cur[7] >= $ROTATE_SIZE && $running->()) {
                eval { rotate($vmid) };
                warn "rotating the line-mode console log of VM $vmid failed - $@" if $@;
            }
        }

        my $state = defined($ino) ? "$ino $offset" : '';
        if ($state ne $last_state) {
            PVE::Tools::file_set_contents(state_file($vmid), "$state\n");
            $last_state = $state;
        }

        my $wait = $sender ? sender_pump($sender, $notice) : undef;
        last if $opts{once};
        if ($wait) {
            IO::Select->new($wait)->can_write($interval);
        } else {
            select(undef, undef, undef, $interval);
        }
    }
}

1;
