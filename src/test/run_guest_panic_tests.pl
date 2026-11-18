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

done_testing();
