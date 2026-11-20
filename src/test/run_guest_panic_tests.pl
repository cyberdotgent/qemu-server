#!/usr/bin/perl

use v5.36;
no warnings 'portable'; # 64-bit hexadecimal literals

use lib qw(..);

use Test::MockModule;
use Test::More;

use PVE::JSONSchema;
use PVE::QemuServer;

# crash-information per QOM path, like QEMU reports it; CPUs without an entry did not crash
my $crash_information;
my $cpus;

my $qemu_server = Test::MockModule->new('PVE::QemuServer');
$qemu_server->mock(
    mon_cmd => sub {
        my ($vmid, $cmd, %params) = @_;

        return $cpus if $cmd eq 'query-cpus-fast';
        die "unexpected command '$cmd'\n" if $cmd ne 'qom-get';
        die "unexpected property '$params{property}'\n"
            if $params{property} ne 'crash-information';

        my $info = $crash_information->{ $params{path} };
        die "No crash occurred\n" if !$info;
        return $info;
    },
);

my sub cpu_list($count) {
    return [map { { 'cpu-index' => $_, 'qom-path' => "/machine/unattached/device[$_]" } }
        0 .. $count - 1];
}

my $tests = [
    {
        name => 's390x disabled wait on the second CPU',
        cpus => 2,
        crash_information => {
            '/machine/unattached/device[1]' => {
                type => 's390',
                core => 1,
                'psw-mask' => 562956395872256,
                'psw-addr' => 0,
                reason => 'disabled-wait',
            },
        },
        expected => {
            type => 's390',
            core => 1,
            'psw-mask' => '0002000180000000',
            'psw-addr' => '0000000000000000',
            reason => 'disabled-wait',
        },
    },
    {
        name => 's390x 64-bit address keeps all digits',
        cpus => 1,
        crash_information => {
            '/machine/unattached/device[0]' => {
                type => 's390',
                core => 0,
                'psw-mask' => 0x0706000180000000,
                'psw-addr' => 18446744073709551614,
                reason => 'pgmint-loop',
            },
        },
        expected => {
            type => 's390',
            core => 0,
            'psw-mask' => '0706000180000000',
            'psw-addr' => 'fffffffffffffffe',
            reason => 'pgmint-loop',
        },
    },
    {
        name => 'Hyper-V crash MSRs',
        cpus => 4,
        crash_information => {
            '/machine/unattached/device[2]' => {
                type => 'hyper-v',
                arg1 => 0x7e,
                arg2 => 0xffffffffc0000005,
                arg3 => 0xfffff8012345678a,
                arg4 => 0,
                arg5 => 1,
            },
        },
        expected => {
            type => 'hyper-v',
            arg1 => '000000000000007e',
            arg2 => 'ffffffffc0000005',
            arg3 => 'fffff8012345678a',
            arg4 => '0000000000000000',
            arg5 => '0000000000000001',
        },
    },
    {
        name => 'no CPU has crash information (pvepanic, older QEMU)',
        cpus => 2,
        crash_information => {},
        expected => undef,
    },
    {
        name => 'unknown crash information type',
        cpus => 1,
        crash_information => {
            '/machine/unattached/device[0]' => { type => 'future-arch', foo => 1 },
        },
        expected => undef,
    },
];

for my $test ($tests->@*) {
    $cpus = cpu_list($test->{cpus});
    $crash_information = $test->{crash_information};

    my $info = PVE::QemuServer::get_guest_panic_info(100);
    is_deeply($info, $test->{expected}, $test->{name});

    if ($info) {
        my $schema = $PVE::QemuServer::vmstatus_return_properties->{'panic-info'};
        eval { PVE::JSONSchema::validate($info, $schema) };
        is($@, '', "$test->{name}: matches the API schema");
    }
}

# the status fields: a disabled wait of an s390x CPU is told apart, other crashes are not
is_deeply(PVE::QemuServer::guest_panic_status_fields(undef), {}, 'no crash information');
my $wait = {
    type => 's390',
    core => 0,
    'psw-mask' => '0002000180000000',
    'psw-addr' => '0000000000000ccc',
    reason => 'disabled-wait',
};
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($wait),
    { 'panic-info' => $wait, 'disabled-wait' => '0000000000000ccc' },
    's390x disabled wait, no OS type: PSW address',
);
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($wait, 'other'),
    { 'panic-info' => $wait, 'disabled-wait' => '0000000000000ccc' },
    's390x disabled wait, OS type other: PSW address',
);
for my $ostype (qw(l26 l24)) {
    is_deeply(
        PVE::QemuServer::guest_panic_status_fields($wait, $ostype),
        { 'panic-info' => $wait },
        "s390x disabled wait, OS type $ostype: a kernel panic, no disabled wait",
    );
}
my $loop = { %$wait, reason => 'pgmint-loop' };
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($loop),
    { 'panic-info' => $loop },
    's390x program interrupt loop: no disabled wait',
);
my $hyperv = { type => 'hyper-v', map { ("arg$_" => '0000000000000001') } 1 .. 5 };
is_deeply(
    PVE::QemuServer::guest_panic_status_fields($hyperv),
    { 'panic-info' => $hyperv },
    'Hyper-V crash: no disabled wait',
);
{
    my $fields = PVE::QemuServer::guest_panic_status_fields($wait);
    for my $key (sort keys $fields->%*) {
        my $schema = $PVE::QemuServer::vmstatus_return_properties->{$key};
        eval { PVE::JSONSchema::validate($fields->{$key}, $schema) };
        is($@, '', "status field '$key' matches the API schema");
    }
}

done_testing();
