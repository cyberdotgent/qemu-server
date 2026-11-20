package PVE::QemuServer::Console3270;

# Persistent sessions for the 3270 consoles of s390x VMs.
#
# QEMU serves each 3270 device of an s390x VM (the integrated 3270 console 'sclp3270console' and
# the 3270 terminals 'x-terminal3270') over TN3270 on a Unix socket. Without a connected client,
# the guest sees a display that is switched off (intervention required), and a mainframe operating
# system may lose its console. So every 3270 device gets a c3270 client for the whole lifetime of
# the VM: each runs in a session of a tmux server per VM, which the systemd unit
# pve-qemu-3270@<vmid>.service holds. The unit is bound to the scope of the VM and stops with it.
# Viewers ('qm terminal', termproxy for the web console) attach to and detach from these sessions,
# several viewers share a session.

use strict;
use warnings;

use PVE::JSONSchema;
use PVE::Tools qw(run_command);

use PVE::QemuServer::Helpers;

our $TMUX_CONFIG = '/usr/share/qemu-server/3270-tmux.conf';

# The screen sizes of the 3270 models.
my $model_sizes = { 2 => [24, 80], 3 => [32, 80], 4 => [43, 80], 5 => [27, 132] };

# The rows of the window of a session besides the 3270 screen: c3270 shows its menu bar in the two
# rows above the screen and its status line below it.
my $extra_rows = 3;

# The c3270 actions that the viewers must not be able to run, from the menus or with keys of the
# default keymap: those that end or change the connection, run commands, scripts or macros, write
# files or print. The c3270 option -secure already removes most of them from the menus and the
# c3270> prompt, but not Disconnect and Quit. Connect stays, c3270 connects to the host with it; no
# menu and no key of the default keymap runs it.
my $suppressed_actions = [
    qw(Quit Exit Disconnect Close Open Reconnect),
    qw(Execute Script Source Macro Prompt Set),
    qw(Printer PrintText Transfer Trace ScreenTrace),
];

# The model of the integrated 3270 console and of terminals without a configured model, fixed for
# the lifetime of the VM (of its sessions): 4 (43x80). A mainframe OS may write 43x80 screens to the integrated
# 3270 console of the HMC, its IPL console, which a model 2 cannot show, and the 3270
# applications of mainframe systems handle model 4 displays as well as model 2 ones.
our $DEFAULT_MODEL = 4;

# The option for the model of the integrated 3270 console, like the 'model' of a 3270 terminal.
our $sclp3270_model_desc = {
    optional => 1,
    type => 'string',
    enum => [qw(2 3 4 5)],
    default => $DEFAULT_MODEL,
    description => "The 3270 model the integrated 3270 console (SCLP) of an s390x VM with a"
        . " mainframe OS type emulates: 2 (24x80), 3 (32x80), 4 (43x80) or 5 (27x132). Its"
        . " session emulates it as long as the VM runs, a change applies at the next start.",
};

sub unit_name {
    my ($vmid) = @_;
    return "pve-qemu-3270\@$vmid.service";
}

sub tmux_socket {
    my ($vmid) = @_;
    return "${PVE::QemuServer::Helpers::var_run_tmpdir}/$vmid.3270.tmux";
}

sub is_3270_iface {
    my ($iface) = @_;
    return $iface eq '3270' || $iface =~ m/^terminal\d+$/;
}

# The 3270 consoles of a VM, { <iface> => <model> }: the integrated 3270 console, if its OS type
# has one, and the 3270 terminals.
sub get_consoles {
    my ($conf) = @_;

    return {} if PVE::QemuServer::Helpers::get_vm_arch($conf) ne 's390x';

    my $consoles = {};
    $consoles->{3270} = $conf->{'sclp3270-model'} // $DEFAULT_MODEL
        if grep { $_ eq '3270' } PVE::QemuServer::Helpers::get_s390x_consoles($conf)->@*;
    for (my $i = 0; $i < $PVE::QemuServer::Helpers::MAX_TERMINALS; $i++) {
        my $value = $conf->{"terminal$i"} or next;
        my $terminal = PVE::JSONSchema::parse_property_string('pve-qm-terminal', $value);
        $consoles->{"terminal$i"} = $terminal->{model} // $DEFAULT_MODEL;
    }
    return $consoles;
}

sub tmux_command {
    my ($vmid, @cmd) = @_;
    return ['/usr/bin/tmux', '-u', '-S', tmux_socket($vmid), @cmd];
}

my sub has_session {
    my ($vmid, $iface) = @_;

    return 0 if !-S tmux_socket($vmid);
    my $res = eval {
        run_command(
            tmux_command($vmid, 'has-session', '-t', "=$iface"),
            quiet => 1,
            noerr => 1,
        );
    };
    return defined($res) && $res == 0;
}

# The size of the window of the session of a 3270 console, [rows, columns].
sub window_size {
    my ($model) = @_;
    my ($rows, $cols) = $model_sizes->{$model}->@*;
    return [$rows + $extra_rows, $cols];
}

# The command of the session of a 3270 console: c3270 with a fixed model, restarted should it
# ever exit, for example when it lost the connection. Viewers can use its menu bar, keypad and the
# mouse, but not quit it, disconnect it or get to a shell.
sub session_command {
    my ($vmid, $iface, $model) = @_;

    my $socket = PVE::QemuServer::Helpers::console_socket($vmid, $iface);
    return [
        '/bin/sh',
        '-c',
        'while :; do /usr/bin/c3270 "$@"; sleep 1; done',
        'c3270',
        '-secure', # no c3270 prompt, viewers must not be able to quit or reconfigure it
        '-model',
        "3279-$model",
        '-xrm',
        'c3270.suppressActions: ' . join(' ', $suppressed_actions->@*),
        '-xrm',
        'c3270.menuBar: true',
        '-xrm',
        'c3270.mouse: true',
        "U:$socket",
    ];
}

# Create the missing sessions of the 3270 consoles of a VM, whose QEMU has their sockets. Only to
# be called by the systemd unit, the tmux server must run in its control group.
sub create_sessions {
    my ($vmid, $conf) = @_;

    my $consoles = get_consoles($conf);
    for my $iface (sort keys $consoles->%*) {
        next if !-S PVE::QemuServer::Helpers::console_socket($vmid, $iface);
        next if has_session($vmid, $iface);

        my $model = $consoles->{$iface};
        my ($rows, $cols) = window_size($model)->@*;
        # The window keeps the size of the 3270 screen whatever the size of the viewers. Set per
        # window: tmux 3.5a crashes creating sessions with a global 'window-size manual'.
        run_command(tmux_command(
            $vmid,
            '-f',
            $TMUX_CONFIG,
            'new-session',
            '-d',
            '-s',
            $iface,
            '-x',
            $cols,
            '-y',
            $rows,
            session_command($vmid, $iface, $model)->@*,
            ';',
            'set-option',
            '-w',
            '-t',
            "=$iface:",
            'window-size',
            'manual',
        ));
    }
}

# Start the sessions of the 3270 consoles of a running VM, without waiting for them.
sub start_sessions {
    my ($vmid, $conf) = @_;

    return if !scalar(keys get_consoles($conf)->%*);

    eval { run_command(['/bin/systemctl', 'start', '--no-block', unit_name($vmid)]) };
    warn "failed to start the 3270 console sessions of VM $vmid - $@" if $@;
}

sub stop_sessions {
    my ($vmid, $conf) = @_;

    # the unit is bound to the scope of the VM anyway, this is to not depend on that
    return if PVE::QemuServer::Helpers::get_vm_arch($conf) ne 's390x';

    eval { run_command(['/bin/systemctl', 'stop', unit_name($vmid)], quiet => 1, noerr => 1); };
    remove_socket($vmid);
}

# Remove the socket the tmux server of a VM leaves behind when it is killed with the unit (after a stop, a migration or the destruction of the VM). The unit removes it too
# (ExecStopPost), this covers VMs whose unit was stopped before.
sub remove_socket {
    my ($vmid) = @_;

    my $socket = tmux_socket($vmid);
    unlink($socket) or warn "unable to remove '$socket' - $!\n" if -S $socket && !-l $socket;
}

# Make sure the session of the 3270 console $iface of a running VM exists, for example after an
# update for VMs started before, or if the unit was stopped.
sub ensure_session {
    my ($vmid, $iface) = @_;

    return if has_session($vmid, $iface);

    # starts the unit, or creates the missing sessions if it is running
    run_command(['/bin/systemctl', 'reload-or-restart', unit_name($vmid)]);

    die "VM $vmid has no 3270 console session '$iface', see 'journalctl -u "
        . unit_name($vmid) . "'\n"
        if !has_session($vmid, $iface);
}

# Attach the terminal to the session of a 3270 console. With $detach_key, Ctrl+] detaches ('qm
# terminal'), without it the viewer sends Ctrl+] to c3270 like any other key and only leaves by
# disconnecting (the web consoles): the client flag ignore-size tells the tmux config, it changes
# nothing else as the windows have a fixed size.
sub attach_command {
    my ($vmid, $iface, $detach_key) = @_;
    return tmux_command(
        $vmid,
        'attach-session',
        ($detach_key ? () : ('-f', 'ignore-size')),
        '-t',
        "=$iface",
    );
}

1;
