#!/usr/bin/perl

use v5.36;

use lib qw(..);

use Test::More;

use PVE::QemuServer::CCW;
use PVE::QemuServer::Network;

my $parse_tests = [
    ['0.0.0200', [0, 0x200]],
    ['0.1.ABCD', [1, 0xabcd]],
    ['200', [0, 0x200]],
    ['0a80', [0, 0xa80]],
    ['0.0.200', [0, 0x200]],
    ['fe.0.0200', undef],
    ['1.0.0200', undef],
    ['0.4.0200', undef],
    ['20', undef],
    ['0.0.10000', undef],
    ['', undef],
    ['0.0.02x0', undef],
];

for my $test ($parse_tests->@*) {
    my ($value, $expected) = $test->@*;
    my @res = eval { PVE::QemuServer::CCW::parse_devno($value) };
    if ($expected) {
        is_deeply(\@res, $expected, "devno '$value' is valid");
    } else {
        ok(!@res && $@, "devno '$value' is invalid");
    }
}

is(PVE::QemuServer::CCW::normalize_devno('0A80'), '0.0.0a80', 'normalized');
is(PVE::QemuServer::CCW::qemu_devno('0.1.0200'), 'fe.1.0200', 'QEMU form');

my $conf = {
    arch => 's390x',
    ckd0 => 'local:100/vm-100-disk-0.raw,devno=0.0.0300,cylinders=3339',
    ckd1 => 'local:100/vm-100-disk-1.raw,devno=0301,cylinders=3339',
    fba0 => 'local:100/vm-100-disk-2.raw,devno=0.0.0200,size=1G',
    virtio0 => 'local:100/vm-100-disk-3.raw,size=1G',
    pending => {
        fba1 => 'local:100/vm-100-disk-4.raw,devno=0.0.0201',
        ckd1 => 'local:100/vm-100-disk-1.raw,devno=0.0.0305,cylinders=3339',
        delete => 'fba0',
    },
};

is_deeply(
    PVE::QemuServer::CCW::get_devno_users($conf),
    [
        { key => 'ckd0', kind => 'ckd', devno => '0.0.0300', count => 1 },
        { key => 'ckd1', kind => 'ckd', devno => '0.0.0305', count => 1 },
        { key => 'fba1', kind => 'fba', devno => '0.0.0201', count => 1 },
    ],
    'devno users with pending changes',
);

is(PVE::QemuServer::CCW::next_free_devno($conf, 'ckd'), '0.0.0301', 'next free CKD');
is(PVE::QemuServer::CCW::next_free_devno($conf, 'fba'), '0.0.0200', 'freed by pending delete');
is(
    PVE::QemuServer::CCW::next_free_devno($conf, 'fba', ['0.0.0200', '202']),
    '0.0.0203',
    'extra used device numbers',
);
is(PVE::QemuServer::CCW::next_free_devno(undef, 'ckd'), '0.0.0300', 'no VM yet');
is(PVE::QemuServer::CCW::next_free_devno(undef, 'qeth'), '0.0.0400', 'qeth default');
is(
    PVE::QemuServer::CCW::next_free_devno(undef, 'qeth', ['0.0.0402']),
    '0.0.0404',
    'qeth triplet aligned to 4',
);
is(PVE::QemuServer::CCW::next_free_devno(undef, 'tape'), '0.0.0580', 'tape default');
is(PVE::QemuServer::CCW::next_free_devno(undef, '3270'), '0.0.0700', '3270 default');
is(
    PVE::QemuServer::CCW::next_free_devno($conf, 'ckd', [], 'ckd0'),
    '0.0.0300',
    'skip the device whose number is chosen',
);

my $full = [map { sprintf('0.0.%04x', $_) } 0x0300 .. 0xffff];
is(PVE::QemuServer::CCW::next_free_devno(undef, 'ckd', $full), '0.0.0100', 'wraps around');
push @$full, map { sprintf('0.0.%04x', $_) } 0x0100 .. 0x02ff;
eval { PVE::QemuServer::CCW::next_free_devno(undef, 'ckd', $full) };
like($@, qr/no free device number/, 'all taken');

eval { PVE::QemuServer::CCW::next_free_devno(undef, 'virtio') };
like($@, qr/assigned by qemu-server/, 'no suggestion for virtio');

eval { PVE::QemuServer::CCW::check_devno_conflicts($conf) };
is($@, '', 'no conflicts');

my $conflict_tests = [
    [
        { ckd0 => 'x:1,devno=0300', fba0 => 'x:2,devno=0.0.0300' },
        qr/^fba0: device number 0\.0\.0300 is already used by ckd0/,
    ],
    [{ fba0 => 'x:2,devno=0.0.0042' }, qr/^fba0: device number 0\.0\.0042 is reserved/],
    [{ fba0 => 'x:2,devno=0.1.0042' }, undef],
    [{ fba0 => 'x:2,devno=0.0.0300', fba1 => 'x:2,devno=0.1.0300' }, undef],
    [{ fba0 => 'x:2,devno=fe.0.0300' }, qr/^fba0: invalid device number/],
];

PVE::QemuServer::CCW::register_devno_user(
    qr/^testqeth\d+$/,
    sub {
        my ($key, $value) = @_;
        return $value =~ m/devno=([^,]+)/ ? ('qeth', $1) : ('qeth', undef);
    },
);
push @$conflict_tests,
    [
        { testqeth0 => 'devno=0.0.0400', ckd0 => 'x:1,devno=0.0.0402' },
        qr/^testqeth0: device number 0\.0\.0402 is already used by ckd0/,
    ],
    [
        { testqeth0 => 'devno=0.0.0401' },
        qr/^testqeth0: device number 0\.0\.0401 must be a multiple of 4/,
    ],
    [{ testqeth0 => 'devno=0.0.fffc' }, undef],
    [{ testqeth0 => 'devno=0.0.ffff' }, qr/leaves no room/];

for my $test ($conflict_tests->@*) {
    my ($test_conf, $expected) = $test->@*;
    my $name = join(' ', map { "$_=$test_conf->{$_}" } sort keys %$test_conf);
    eval { PVE::QemuServer::CCW::check_devno_conflicts($test_conf) };
    if ($expected) {
        like($@, $expected, "conflict: $name");
    } else {
        is($@, '', "no conflict: $name");
    }
}

is(
    PVE::QemuServer::CCW::next_free_devno({ tape0 => 'local:iso/a.aws', tape1 => 'none' }, 'tape'),
    '0.0.0582',
    'tape drives have default device numbers',
);
eval {
    PVE::QemuServer::CCW::check_devno_conflicts(
        { tape0 => 'none', ckd0 => 'local:1/x.raw,devno=0580' },
    );
};
like($@, qr/^tape0: device number 0\.0\.0580 is already used by ckd0/, 'tape conflict');

is(
    PVE::QemuServer::CCW::next_free_devno({ testqeth0 => 'devno=0.0.0400' }, 'qeth'),
    '0.0.0404',
    'next qeth after a registered user',
);

my $qeth_terminal_conf = {
    net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0,devno=0.0.0400',
    net1 => 'virtio=BC:24:11:00:00:02,bridge=vmbr0',
    net2 => 'bridge=vmbr0,model=qeth,devno=0404',
    net3 => 'qeth=BC:24:11:00:00:03,bridge=vmbr0',
    terminal0 => '0.0.0700',
    terminal1 => 'model=4,devno=0701',
    terminal2 => '0702,model=5',
};
is_deeply(
    PVE::QemuServer::CCW::get_devno_users($qeth_terminal_conf),
    [
        { key => 'net0', kind => 'qeth', devno => '0.0.0400', count => 3 },
        { key => 'net2', kind => 'qeth', devno => '0404', count => 3 },
        { key => 'net3', kind => 'qeth', devno => undef, count => 3 },
        { key => 'terminal0', kind => '3270', devno => '0.0.0700', count => 1 },
        { key => 'terminal1', kind => '3270', devno => '0701', count => 1 },
        { key => 'terminal2', kind => '3270', devno => '0702', count => 1 },
    ],
    'qeth network devices and 3270 terminals use device numbers',
);
is(
    PVE::QemuServer::CCW::next_free_devno($qeth_terminal_conf, 'qeth'),
    '0.0.0408',
    'next free qeth after two adapters',
);
is(
    PVE::QemuServer::CCW::next_free_devno($qeth_terminal_conf, '3270'),
    '0.0.0703',
    'next free 3270 terminal',
);
eval {
    PVE::QemuServer::CCW::check_devno_conflicts(
        { net0 => 'qeth=BC:24:11:00:00:01,devno=0.0.0700', terminal0 => '0.0.0702' });
};
like(
    $@,
    qr/^terminal0: device number 0\.0\.0702 is already used by net0/,
    'a qeth adapter uses three device numbers',
);

# qeth adapters without a device number get one when they are created or changed
{
    my $assign = sub { PVE::QemuServer::Network::assign_qeth_devno(@_) };
    is(
        $assign->($qeth_terminal_conf, 'net3', $qeth_terminal_conf->{net3}),
        'qeth=BC:24:11:00:00:03,bridge=vmbr0,devno=0.0.0408',
        'qeth adapter without a device number gets the next free one',
    );
    is(
        $assign->(
            $qeth_terminal_conf, 'net0', 'qeth=BC:24:11:00:00:01,bridge=vmbr1',
        ),
        'qeth=BC:24:11:00:00:01,bridge=vmbr1,devno=0.0.0400',
        'a changed qeth adapter keeps its device number',
    );
    is(
        $assign->($qeth_terminal_conf, 'net1', 'qeth=BC:24:11:00:00:02,bridge=vmbr0'),
        'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0408',
        'a VirtIO adapter changed to qeth gets the next free one',
    );
    is(
        $assign->({}, 'net0', 'virtio=BC:24:11:00:00:02,bridge=vmbr0'),
        'virtio=BC:24:11:00:00:02,bridge=vmbr0',
        'VirtIO adapters are left alone',
    );
    is(
        $assign->({}, 'net0', 'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0480'),
        'qeth=BC:24:11:00:00:02,bridge=vmbr0,devno=0.0.0480',
        'a configured device number is kept',
    );

    # as on VM creation: the config is the new VM's parameters
    my $new = {
        net0 => 'qeth=BC:24:11:00:00:01,bridge=vmbr0',
        net1 => 'qeth=BC:24:11:00:00:02,bridge=vmbr0',
        net2 => 'qeth=BC:24:11:00:00:03,bridge=vmbr0,devno=0.0.0404',
    };
    $new->{$_} = $assign->($new, $_, $new->{$_}) for sort keys $new->%*;
    is_deeply(
        [map { $new->{$_} =~ m/devno=([^,]+)/ ? $1 : undef } sort keys $new->%*],
        ['0.0.0400', '0.0.0408', '0.0.0404'],
        'new VM: qeth adapters get distinct device numbers around configured ones',
    );
    eval { PVE::QemuServer::CCW::check_devno_conflicts($new) };
    is($@, '', 'new VM: no conflicts');
}

done_testing();
