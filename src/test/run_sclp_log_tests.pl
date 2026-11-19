#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::More;

use PVE::QemuServer::SclpLog;

my $dir = tempdir(CLEANUP => 1);
$PVE::QemuServer::SclpLog::LOG_DIR = $dir;

my $vmid = 100;
my $path = PVE::QemuServer::SclpLog::log_path($vmid);
is($path, "$dir/100-sclplm.log", 'log path');

is_deeply(
    PVE::QemuServer::SclpLog::read_log($vmid),
    { id => '', size => 0, start => 0, end => 0, data => '', complete => 1 },
    'no log yet',
);

PVE::QemuServer::SclpLog::prepare_start($vmid, 0);
ok(-e $path, 'start creates the log');
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

$res = PVE::QemuServer::SclpLog::read_log($vmid, undef, 16);
is($res->{data}, "\x{2500} line 3\n", 'tail starts at a line start');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 7);
is($res->{data}, "line 2\n\x{2500} line 3\n", 'read from an offset');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 1_000_000);
is($res->{start}, $size, 'offset beyond the end is clamped');
is($res->{data}, '', 'nothing beyond the end');

$res = PVE::QemuServer::SclpLog::read_log($vmid, 0, undef, 10);
is($res->{data}, "line 1\n", 'limit, whole lines');

PVE::QemuServer::SclpLog::prepare_start($vmid, 1);
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0);
is($res->{id}, $id, 'resuming from a saved state continues the log');
like(
    $res->{data},
    qr/^part\x{2500}{4} VM resumed from a saved state at \S+ \S+ \x{2500}{4}\n\z/m,
    'resume marker',
);

sleep(1); # the id includes the mtime, a new log in the same second can get the same inode
PVE::QemuServer::SclpLog::prepare_start($vmid, 0);
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0);
isnt($res->{id}, $id, 'a fresh start begins a new log');
is($res->{size}, 0, 'the new log is empty');
$res = PVE::QemuServer::SclpLog::read_log($vmid, 0, undef, undef, 1);
like($res->{data}, qr/^line 1\n/, 'the previous log is kept');

PVE::QemuServer::SclpLog::remove_logs($vmid);
ok(!-e $path && !-e "$path.1", 'logs removed');

for my $bad ("a\rb", "a\nb", "\e[A", ' ', 'x' x 252) {
    eval { PVE::QemuServer::SclpLog::check_command($bad) };
    ok($@, "refused command " . join('', map { sprintf('%02x', ord($_)) } split(//, substr($bad, 0, 4))));
}
eval { PVE::QemuServer::SclpLog::check_command('d a,l') };
is($@, '', 'command accepted');

done_testing();
