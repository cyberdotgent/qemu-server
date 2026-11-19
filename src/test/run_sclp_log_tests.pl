#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Encode qw(decode);
use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;

use PVE::QemuServer::Helpers;
use PVE::QemuServer::SclpLog;

my $dir = tempdir(CLEANUP => 1);
$PVE::QemuServer::SclpLog::LOG_DIR = $dir;
$PVE::QemuServer::Helpers::var_run_tmpdir = $dir;

my $stopped_units = [];
my $sclplog_module = Test::MockModule->new('PVE::QemuServer::SclpLog');
$sclplog_module->mock(stop_unit => sub { push @$stopped_units, $_[0]; });

my $vmid = 100;
my $path = PVE::QemuServer::SclpLog::log_path($vmid);
is($path, "$dir/100-sclplm.log", 'log path');
is(PVE::QemuServer::SclpLog::log_path($vmid, 3), "$dir/100-sclplm.log.3", 'generation path');

is_deeply(
    PVE::QemuServer::SclpLog::read_log($vmid),
    { id => '', size => 0, start => 0, end => 0, data => '', complete => 1 },
    'no log yet',
);

PVE::QemuServer::SclpLog::prepare_start($vmid, 'start');
ok(-e $path, 'start creates the log');
is(-s $path, 0, 'the first log starts empty');
is((stat($path))[2] & 07777, 0640, 'log is not world-readable');

PVE::QemuServer::SclpLog::append_log($vmid, "line 1\nline 2\n\x{2500} line 3\npart");
my $size = -s $path;

my $res = PVE::QemuServer::SclpLog::read_log($vmid, 0);
is($res->{data}, "line 1\nline 2\n\x{2500} line 3\n", 'whole lines only, UTF-8 decoded');
is($res->{start}, 0, 'start');
is($res->{end}, $size - 4, 'end before the partial line');
ok(!$res->{complete}, 'not complete with a partial line');
my $id = $res->{id};
ok(length($id), 'log has an id');

PVE::QemuServer::SclpLog::append_log($vmid, "\nmore\n");
is(PVE::QemuServer::SclpLog::read_log($vmid, 0)->{id}, $id, 'the id stays while the log grows');

$res = PVE::QemuServer::SclpLog::read_log($vmid, undef, 16);
like($res->{data}, qr/^[^\n]*\n(?:more\n)?$/, 'tail starts at a line start');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 7);
like($res->{data}, qr/^line 2\n\x{2500} line 3\n/, 'read from an offset');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 1_000_000);
is($res->{data}, '', 'nothing beyond the end');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 0, undef, 10);
is($res->{data}, "line 1\n", 'limit, whole lines');

PVE::QemuServer::SclpLog::prepare_start($vmid, 'resume');
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0);
is($res->{id}, $id, 'resuming from a saved state continues the log');
like(
    $res->{data},
    qr/\n\x{2500}{4} VM resumed from a saved state at \S+ \S+ \x{2500}{4}\n\z/,
    'resume marker',
);

PVE::QemuServer::SclpLog::prepare_start($vmid, 'start');
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0);
isnt($res->{id}, $id, 'a fresh start begins a new log');
like(
    $res->{data},
    qr/^\x{2500}{4} VM 100 started, the previous log is 100-sclplm\.log\.1 at /,
    'the new log names the previous one',
);
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0, undef, undef, 1);
like($res->{data}, qr/^line 1\n/, 'the previous log is generation 1');
is_deeply(PVE::QemuServer::SclpLog::generations($vmid), [1], 'one older generation');

my $files = PVE::QemuServer::SclpLog::list_files($vmid);
is_deeply([map { $_->{name} } @$files], ['100-sclplm.log', '100-sclplm.log.1'], 'file list');

# input lines
my $input = PVE::QemuServer::SclpLog::input_line('root@pam', 'd a,l');
like($input, qr/^\x{25b6}{4} root\@pam \d{4}-\d\d-\d\d \d\d:\d\d:\d\d: d a,l\n$/, 'input line');
like(
    PVE::QemuServer::SclpLog::input_line('root@pam', 'map', 'terminal'),
    qr/^\x{25b6}{4} root\@pam \(terminal\) \S+ \S+: map\n$/,
    'terminal input line',
);

# rotation with QEMU switching the hardcopy (chardev-change)
my $monitor = Test::MockModule->new('PVE::QemuServer::SclpLog');
my @qmp;
my $qmp_fails = 0;
$monitor->mock(
    mon_cmd => sub {
        my ($id, $cmd, %args) = @_;
        push @qmp, [$cmd, $args{id}, $args{backend}->{data}->{out}];
        die "Chardev user does not support chardev hotswap\n" if $qmp_fails;
        return {};
    },
);

PVE::QemuServer::SclpLog::append_log($vmid, "before rotation\n");
my $ino = (stat($path))[1];
PVE::QemuServer::SclpLog::rotate($vmid);
is_deeply(\@qmp, [['chardev-change', 'sclplm-hardcopy', $path]], 'QEMU switched to the new file');
is((stat(PVE::QemuServer::SclpLog::log_path($vmid, 1)))[1], $ino, 'the rotated file is .1');
is_deeply(PVE::QemuServer::SclpLog::generations($vmid), [1, 2], 'generations shifted');
like(
    PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data},
    qr/^\x{2500}{4} log continued from 100-sclplm\.log\.1 at \S+ \S+ \x{2500}{4}\n\z/,
    'the new file starts with a marker',
);

# rotation with a QEMU that cannot switch: copy and truncate
$qmp_fails = 1;
PVE::QemuServer::SclpLog::append_log($vmid, "older qemu\n");
$ino = (stat($path))[1];
PVE::QemuServer::SclpLog::rotate($vmid);
is((stat($path))[1], $ino, 'the file QEMU has open stays the current one');
like(
    PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data},
    qr/^\x{2500}{4} log continued from 100-sclplm\.log\.1 /,
    'truncated, with a marker',
);
like(
    PVE::QemuServer::SclpLog::read_log($vmid, 0, undef, undef, 1)->{data},
    qr/older qemu\n\z/,
    'the copy is generation 1',
);
is_deeply(PVE::QemuServer::SclpLog::generations($vmid), [1, 2, 3], 'three generations');

# the total size limit removes the oldest generations, never the current one or .1
{
    local $PVE::QemuServer::SclpLog::ROTATE_SIZE = 1000;
    local $PVE::QemuServer::SclpLog::MAX_TOTAL_SIZE = 5000;
    $qmp_fails = 0;
    for my $i (1 .. 8) {
        PVE::QemuServer::SclpLog::append_log($vmid, join("", ("x" x 99 . "\n") x 10));
        PVE::QemuServer::SclpLog::rotate($vmid);
    }
    my $total = 0;
    $total += $_->{size} for PVE::QemuServer::SclpLog::list_files($vmid)->@*;
    ok($total + 1000 <= 5000, "within the total size with room for the current file ($total)");
    my $gens = PVE::QemuServer::SclpLog::generations($vmid);
    is_deeply($gens, [1 .. scalar(@$gens)], 'generations stay contiguous');
    ok(scalar(@$gens) >= 2 && scalar(@$gens) <= 4, 'oldest generations removed');
}

# resume and backup starts continue the log: one marker for a resume, none for a backup, no
# rotation, and the forwarder keeps its position
{
    PVE::QemuServer::SclpLog::prepare_start($vmid, 'start');
    PVE::QemuServer::SclpLog::append_log($vmid, "guest line\n");
    my $state = PVE::QemuServer::SclpLog::state_file($vmid);
    PVE::Tools::file_set_contents($state, "1 2\n");
    my $gens = PVE::QemuServer::SclpLog::generations($vmid);
    my $before = PVE::QemuServer::SclpLog::read_log($vmid, 0);

    PVE::QemuServer::SclpLog::prepare_start($vmid, 'resume');
    my $after = PVE::QemuServer::SclpLog::read_log($vmid, 0);
    is($after->{id}, $before->{id}, 'resume: same file');
    is_deeply(PVE::QemuServer::SclpLog::generations($vmid), $gens, 'resume: no rotation');
    my $added = substr($after->{data}, length($before->{data}));
    like($added, qr/^\x{2500}{4} VM resumed from a saved state at [^\n]+\n\z/, 'resume: one marker');
    ok(-e $state, 'resume: forwarder position kept');

    $before = $after;
    PVE::QemuServer::SclpLog::prepare_start($vmid, 'backup');
    $after = PVE::QemuServer::SclpLog::read_log($vmid, 0);
    is($after->{id}, $before->{id}, 'backup start: same file');
    is($after->{data}, $before->{data}, 'backup start: no marker');
    is_deeply(PVE::QemuServer::SclpLog::generations($vmid), $gens, 'backup start: no rotation');
    ok(-e $state, 'backup start: forwarder position kept');

    eval { PVE::QemuServer::SclpLog::prepare_start($vmid, 1) };
    like($@, qr/^unknown start type/, 'start type checked');

    PVE::QemuServer::SclpLog::prepare_start($vmid, 'start');
    ok(!-e $state, 'fresh start: forwarder starts over');
    is_deeply(
        PVE::QemuServer::SclpLog::generations($vmid),
        [1 .. scalar(@$gens) + 1],
        'fresh start: rotation',
    );
}

# a backup start of a VM without a log creates it, not world-readable, without a marker
{
    my $other = 101;
    PVE::QemuServer::SclpLog::prepare_start($other, 'backup');
    my $p = PVE::QemuServer::SclpLog::log_path($other);
    ok(-e $p && -s $p == 0, 'backup start without a log: empty log');
    is((stat($p))[2] & 07777, 0640, 'backup start without a log: mode 0640');
    PVE::QemuServer::SclpLog::remove_logs($other);
}

# the guest of a backup VM is started: one marker, only while QEMU is in prelaunch
{
    my $status = 'prelaunch';
    $sclplog_module->mock(mon_cmd => sub { return { status => $status }; });
    my $conf = { arch => 's390x', ostype => 'other' };
    my $before = PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data};
    PVE::QemuServer::SclpLog::backup_vm_started($vmid, $conf);
    my $data = PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data};
    like(
        substr($data, length($before)),
        qr/^\x{2500}{4} VM 100 started during a backup at [^\n]+\n\z/,
        'start during a backup: marker',
    );
    $status = 'running';
    PVE::QemuServer::SclpLog::backup_vm_started($vmid, $conf);
    is(PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data}, $data, 'already running: no marker');
    $status = 'prelaunch';
    PVE::QemuServer::SclpLog::backup_vm_started($vmid, { arch => 's390x', ostype => 'l26' });
    is(PVE::QemuServer::SclpLog::read_log($vmid, 0)->{data}, $data, 'no line-mode console: no marker');
    $sclplog_module->unmock('mon_cmd');
}

# destroy: all generations, the forwarder position and the lock go, the unit stops
PVE::Tools::file_set_contents(PVE::QemuServer::SclpLog::state_file($vmid), "1 2\n");
$stopped_units = [];
PVE::QemuServer::SclpLog::remove_logs($vmid);
ok(!-e $path && !scalar(PVE::QemuServer::SclpLog::generations($vmid)->@*), 'logs removed');
ok(!-e PVE::QemuServer::SclpLog::state_file($vmid), 'forwarder position removed');
ok(!-e "$dir/$vmid.sclplm.lock", 'lock file removed');
is_deeply($stopped_units, [$vmid], 'unit stopped');

# commands
for my $bad ("a\rb", "a\nb", "\e[A", ' ', 'x' x 252) {
    eval { PVE::QemuServer::SclpLog::check_command($bad) };
    ok($@, "refused command " . join('', map { sprintf('%02x', ord($_)) } split(//, substr($bad, 0, 4))));
}
eval { PVE::QemuServer::SclpLog::check_command('d a,l') };
is($@, '', 'command accepted');

# following QEMU's line editor: the line the operator entered, after their edits
my $t = PVE::QemuServer::SclpLog::new_line_tracker();
my @done = PVE::QemuServer::SclpLog::track_output(
    $t,
    "d\e[K\e[Dd \e[K\e[D\e[Dd a\e[K" # typing 'd a', redrawn each time
        . "\e[D\e[D\e[Dd \e[K" # backspace
        . "\e[D\e[Dd x\e[K" # 'x'
        . "\n" # Enter
        . "OPERATOR CONSOLE READY\n",
);
is_deeply(\@done, ['d x', 'OPERATOR CONSOLE READY'], 'line editor output followed');

# syslog messages (RFC 5424)
my $cfg = PVE::QemuServer::SclpLog::parse_syslog('host=log.example.com,proto=tcp');
is_deeply(
    $cfg,
    { host => 'log.example.com', proto => 'tcp', port => 514, facility => 'local0' },
    'syslog option defaults',
);
is_deeply(
    PVE::QemuServer::SclpLog::parse_syslog('::1,port=1514,facility=local7'),
    { host => '::1', proto => 'udp', port => 1514, facility => 'local7' },
    'IPv6 host as default key',
);
eval { PVE::QemuServer::SclpLog::parse_syslog('host=bad host') };
ok($@, 'invalid host refused');

my $time = 1795080000.25;
my $out = decode('UTF-8',
    PVE::QemuServer::SclpLog::syslog_message($cfg, 300, 'mf01', 'OPERATOR CONSOLE READY', $time));
like(
    $out,
    qr/^<134>1 \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.250000[+-]\d\d:\d\d mf01 pve-sclplm 300 OUT - OPERATOR CONSOLE READY$/,
    'output: local0.info, MSGID OUT',
);
$out = decode('UTF-8', PVE::QemuServer::SclpLog::syslog_message(
    $cfg, 300, 'mf01', "\x{25b6}\x{25b6}\x{25b6}\x{25b6} root\@pam 2026-11-20 10:15:03: d a,l", $time,
));
like($out, qr/^<133>1 \S+ mf01 pve-sclplm 300 IN - root\@pam: d a,l$/, 'input: notice, MSGID IN');
$out = decode('UTF-8', PVE::QemuServer::SclpLog::syslog_message(
    $cfg, 300, undef, "\x{2500}\x{2500}\x{2500}\x{2500} IPL 0.0.0200 at 2026-11-20 10:15:03 \x{2500}\x{2500}\x{2500}\x{2500}", $time,
));
like($out, qr/^<133>1 \S+ vm300 pve-sclplm 300 MARK - \x{2500}{4} IPL /, 'marker: MSGID MARK, VMID as host without a name');

# the queue of a TCP sender is bounded: the oldest messages are dropped and counted
{
    my $s = PVE::QemuServer::SclpLog::new_sender({ proto => 'tcp', host => '127.0.0.1', port => 9 });
    $s->{max_messages} = 3;
    PVE::QemuServer::SclpLog::sender_send($s, "m$_") for 1 .. 5;
    is_deeply($s->{queue}, ['2 m3', '2 m4', '2 m5'], 'queue keeps the newest, octet-counted');
    is($s->{dropped}, 2, 'dropped messages counted');
}

# the code page of the line-mode console
is(PVE::QemuServer::SclpLog::codepage_property({}), undef, 'code page: QEMU default (037)');
is(PVE::QemuServer::SclpLog::codepage_property({ 'sclplm-codepage' => 'cp037' }), undef,
    'code page 037: QEMU default');
is(PVE::QemuServer::SclpLog::codepage_property({ 'sclplm-codepage' => 'cp500' }), '500',
    'code page 500 (Linux)');

done_testing();
