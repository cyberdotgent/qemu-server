#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use JSON;
use Test::MockModule;
use Test::More;

use PVE::QemuServer::DASD;
use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::IPL;
use PVE::QemuMigrate::Helpers;

my $cyl = 852480;

# QEMU-mod up to pve-qemu-kvm 11.1.90-1+s390x9: no slack after the cylinders of zPDT images
my $dasd = Test::MockModule->new('PVE::QemuServer::DASD');
our $slack_supported = 0;
$dasd->mock(ckd_slack_supported => sub { return $slack_supported });

is(PVE::QemuServer::DASD::ckd_cylinder_size(), $cyl, 'cylinder size');
is(PVE::QemuServer::DASD::ckd_volume_size(3339), 512 + 3339 * $cyl, '3390-3 volume size');
is(PVE::QemuServer::DASD::ckd_alloc_size_kib(3339), 2779718, '3390-3 in KiB, rounded up');
is(PVE::QemuServer::DASD::ckd_alloc_size_kib(32760), 27272701, '3390-27 in KiB, rounded up');

for my $test (
    [{ model => '3390-1' }, 1113],
    [{ model => '3390-2' }, 2226],
    [{ model => '3390-3' }, 3339],
    [{ model => '3390-9' }, 10017],
    [{ model => '3390-27' }, 32760],
    [{ model => '3390-54' }, 65520],
    [{ cylinders => 100 }, 100],
    [{ model => '3390-9', cylinders => 10017 }, 10017],
    [{ model => '3390-9', cylinders => 10016 }, qr/does not match model 3390-9/],
    [{ model => '3390-A' }, qr/unknown CKD model/],
    [{}, qr/need 'model' or 'cylinders'/],
    [{ cylinders => 65521 }, qr/1 to 65520 cylinders/],
) {
    my ($drive, $expected) = $test->@*;
    my $name = join(',', map { "$_=$drive->{$_}" } sort keys %$drive) || 'nothing';
    my $res = eval { PVE::QemuServer::DASD::ckd_cylinders_of_drive($drive) };
    if (ref($expected)) {
        like($@, $expected, "cylinders of $name: error");
    } else {
        is($res, $expected, "cylinders of $name");
    }
}

# the header as in QEMU-mod's docs/system/s390x/3390.rst, plus the serial
my $header = PVE::QemuServer::DASD::ckd_header(3339, '876955967561');
is(length($header), 512, 'header length');
is(
    substr($header, 0, 32),
    "CKD_P064\x0f\0\0\0\0\xde\0\0\x90\0\x0b\x0d876955967561",
    'header content',
);
is(substr($header, 32), "\0" x 480, 'header padding');
like(
    substr(PVE::QemuServer::DASD::ckd_header(1113), 20, 12),
    qr/^\d{12}$/,
    'random decimal serial',
);

my $parse = sub {
    my ($data, $length) = @_;
    return eval { PVE::QemuServer::DASD::parse_ckd_header($data, $length) } // $@;
};

is_deeply(
    $parse->($header, 512 + 3339 * $cyl + 4 * 1024 * 1024),
    {
        identifier => 'CKD_P064',
        cylinders => 3339,
        serial => '876955967561',
        'high-cylinder' => 3339,
        'file-sequence' => 0,
    },
    'header with cylinder count, slack',
);

my $hercules = $header;
substr($hercules, 18, 2, "\0\0"); # high_cylinder 0, as Hercules writes it
substr($hercules, 0, 8, 'CKD_P370');
is($parse->($hercules, 512 + 10017 * $cyl)->{cylinders}, 10017, 'Hercules header, exact length');
is($parse->($hercules, 512 + 10017 * $cyl)->{'high-cylinder'}, 0, 'Hercules high cylinder');
like($parse->($hercules, 512 + 10017 * $cyl + 512), qr/whole cylinders/, 'Hercules header, slack');
like($parse->($header, 512 + 3338 * $cyl), qr/too short for 3339/, 'too short');

my $multi = $hercules;
substr($multi, 17, 3, "\x01\x0f\x27"); # file 1, last cylinder 9999
like($parse->($multi, 512 + 10017 * $cyl), qr/multi-file/, 'multi-file member');

my $old_single = $hercules;
substr($old_single, 17, 3, "\x01\x21\x27"); # file 1, high cylinder = cylinder count
is($parse->($old_single, 512 + 10017 * $cyl)->{cylinders}, 10017, 'old single-file form');

for my $id (qw(CKD_C370 CKD_S370 CKD_C064 CKD_S064)) {
    my $compressed = $header;
    substr($compressed, 0, 8, $id);
    like($parse->($compressed, 1024 * 1024), qr/compressed \(CCKD\)/, "$id refused");
}
my $cfba = $header;
substr($cfba, 0, 8, 'FBA_C370');
like($parse->($cfba, 1024 * 1024), qr/compressed FBA/, 'CFBA is no CKD image');
like($parse->("\0" x 512, 1024 * 1024), qr/no CKD_P370 or CKD_P064 header/, 'no header');

my $ckd3380 = $header;
substr($ckd3380, 8, 9, pack('V V C', 15, 47968, 0x80));
like($parse->($ckd3380, 1024 * 1024 * 1024), qr/only 3390 volumes/, '3380 refused');

# FBA import checks
my $head = "\0" x 512;
$dasd->mock(read_image_head => sub { return $head; });

eval { PVE::QemuServer::DASD::check_fba_import_source('/x.img', 'raw', 1024 * 1024) };
is($@, '', 'FBA import of a raw image');
eval { PVE::QemuServer::DASD::check_fba_import_source('/x.img', 'raw', 1000) };
like($@, qr/multiple of 512/, 'FBA import of an odd size');
eval { PVE::QemuServer::DASD::check_fba_import_source('/x.img', 'raw', 2 * 2**40 + 512) };
like($@, qr/at most 2 TiB/, 'FBA import of more than 2 TiB');
$head = 'FBA_C064' . ("\0" x 504);
eval { PVE::QemuServer::DASD::check_fba_import_source('/x.img', 'raw', 1024 * 1024) };
like($@, qr/compressed FBA \(CFBA\)/, 'FBA import of a CFBA image');
$head = $header;
eval { PVE::QemuServer::DASD::check_fba_import_source('/x.img', 'raw', 1024 * 1024) };
like($@, qr/it is a CKD image/, 'FBA import of a CKD image');
eval { PVE::QemuServer::DASD::check_ckd_import_source('/x.ckd', 'raw', 512 + 3339 * $cyl); };
is($@, '', 'CKD import');
eval { PVE::QemuServer::DASD::check_ckd_import_source('/x.ckd', 'raw', 512 + 3000 * $cyl) };
like($@, qr/^cannot import '\/x.ckd' as CKD volume: CKD image is too short/, 'CKD import, short');
$dasd->unmock('read_image_head');

# volume names
my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(
    storage_config => sub {
        my ($cfg, $storeid) = @_;
        return $cfg->{$storeid};
    },
);
my $storecfg = {
    local => { path => '/var/lib/vz' },
    'local-lvm' => {},
    lvm => { 'snapshot-as-volume-chain' => 1 },
};
is(
    PVE::QemuServer::DASD::dasd_volume_name($storecfg, 'local', 100, 'raw', 'SYSRS1'),
    'vm-100-SYSRS1.raw',
    'name on directory storage',
);
is(
    PVE::QemuServer::DASD::dasd_volume_name($storecfg, 'local-lvm', 100, 'raw', 'SYSRS1'),
    'vm-100-SYSRS1',
    'name on block storage',
);
is(
    PVE::QemuServer::DASD::dasd_volume_name($storecfg, 'lvm', 100, 'qcow2', 'WORK01'),
    'vm-100-WORK01.qcow2',
    'name of a qcow2 volume chain',
);
is(PVE::QemuServer::DASD::dasd_volume_name($storecfg, 'local', 100, 'raw', undef),
    undef, 'no name');

# drive schema
my $drive = PVE::QemuServer::Drive::parse_drive(
    'ckd3',
    'local:100/vm-100-disk-0.raw,devno=0.0.0200,cylinders=10017,ro=1',
);
is_deeply(
    $drive,
    {
        file => 'local:100/vm-100-disk-0.raw',
        devno => '0.0.0200',
        cylinders => 10017,
        ro => 1,
        interface => 'ckd',
        index => 3,
    },
    'parse CKD drive',
);
ok(PVE::QemuServer::Drive::drive_is_dasd($drive), 'CKD is a DASD');
ok(
    !PVE::QemuServer::Drive::parse_drive('ckd0', 'local:100/vm-100-disk-0.raw,cache=none'),
    'no cache option for DASDs',
);
ok(
    !PVE::QemuServer::Drive::parse_drive('fba0', 'local:100/vm-100-disk-0.raw,devno=fe.0.0200'),
    'guest device numbers only',
);
ok(PVE::QemuServer::Drive::parse_drive('ckd0', 'local:0,model=3390-9'), 'model is stored in the config');
is(
    PVE::QemuServer::Drive::parse_drive('ckd0', 'local:0,model=3390-9,name=SYSRS1', 1)->{model},
    '3390-9',
    'model on alloc',
);
ok(
    !PVE::QemuServer::Drive::parse_drive('virtio0', 'local:0,name=SYSRS1', 1),
    'name only for DASDs',
);
is(
    PVE::QemuServer::Drive::print_drive($drive),
    'local:100/vm-100-disk-0.raw,cylinders=10017,devno=0.0.0200,ro=1',
    'print CKD drive',
);
ok(PVE::QemuServer::Drive::is_valid_drivename('fba31'), 'fba31');
ok(!PVE::QemuServer::Drive::is_valid_drivename('fba32'), 'no fba32');
ok(PVE::QemuServer::Drive::is_valid_drivename('ckd63'), 'ckd63');
ok(!PVE::QemuServer::Drive::is_valid_drivename('ckd64'), 'no ckd64');

# IPL devices
my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
$helpers->mock(
    kvm_device_ipl_methods => sub {
        my ($binary, $types) = @_;
        return { map { $_ => 'ccw' } @$types };
    },
);
my $conf = {
    arch => 's390x',
    ckd0 => 'local:100/vm-100-disk-0.raw,devno=0.0.0200,cylinders=10017',
    fba0 => 'local:100/vm-100-disk-1.raw,devno=0.1.0300',
    fba1 => 'local:100/vm-100-cloudinit.qcow2,media=cdrom,devno=0.0.0301',
};
is_deeply(
    PVE::QemuServer::IPL::get_ipl_devices($conf, {}, '/usr/bin/kvm'),
    [
        {
            key => 'ckd0',
            type => 'eckd-ccw',
            devno => 'fe.0.0200',
            'ipl-method' => 'ccw',
            description => 'CKD DASD local:100/vm-100-disk-0.raw',
        },
        {
            key => 'fba0',
            type => 'fba-ccw',
            devno => 'fe.1.0300',
            'ipl-method' => 'ccw',
            description => 'FBA DASD local:100/vm-100-disk-1.raw',
        },
    ],
    'DASDs are IPL devices, cloud-init is not',
);

# RAM snapshots, hibernation and live migration with CKD volumes
eval { PVE::QemuMigrate::Helpers::check_non_migratable_resources($conf, 1, 0) };
is($@, '', 'CKD allows VM state');
eval { PVE::QemuMigrate::Helpers::check_non_migratable_resources($conf, 0, 0) };
is($@, '', 'CKD allows offline operations');

# header I/O with the real tools, if installed
SKIP: {
    skip 'qemu-img/qemu-io not installed', 33 if !-x '/usr/bin/qemu-img' || !-x '/usr/bin/qemu-io';

    my $dir = tempdir(CLEANUP => 1);
    for my $format (qw(raw qcow2)) {
        my $path = "$dir/test.$format";
        my $size = PVE::QemuServer::DASD::ckd_volume_size(1113) + 4096;
        PVE::Tools::run_command(
            ['/usr/bin/qemu-img', 'create', '-f', $format, $path, $size],
            outfunc => sub { },
        );
        PVE::QemuServer::DASD::write_image_head($path, $format, $header);
        my $read = PVE::QemuServer::DASD::read_image_head($path, $format);
        is($read, $header, "$format: header written and read back");
        like(
            $parse->($read, $size),
            qr/too short for 3339/,
            "$format: volume too short for the header's cylinders",
        );
        PVE::QemuServer::DASD::write_image_head(
            $path,
            $format,
            PVE::QemuServer::DASD::ckd_header(1113, '000000000001'),
        );
        is(
            $parse->(PVE::QemuServer::DASD::read_image_head($path, $format), $size)->{cylinders},
            1113,
            "$format: rewritten header",
        );
    }

    # a volume through the storage layer: create, attach a Hercules image
    my $vol = "$dir/vm-100-SYSRS1.raw";
    $storage->mock(
        activate_volumes => sub { },
        path => sub { return $vol; },
        parse_volname =>
            sub { return ('images', 'vm-100-SYSRS1.raw', 100, undef, undef, undef, 'raw'); },
        volume_size_info => sub { return -s $vol; },
        parse_volume_id => sub { return ('local-lvm', 'vm-100-SYSRS1'); },
        storage_config => sub { return { type => 'lvmthin', content => { images => 1 } }; },
    );
    open(my $fh, '>', $vol) or die;
    close($fh);
    truncate($vol, PVE::QemuServer::DASD::ckd_alloc_size_kib(1113) * 1024 + 4 * 1024 * 1024);
    PVE::QemuServer::DASD::init_ckd_volume({}, 'local:100/vm-100-SYSRS1.raw', 1113);
    my $checked = PVE::QemuServer::DASD::check_ckd_volume({}, 'local:100/vm-100-SYSRS1.raw');
    is($checked->{cylinders}, 1113, 'new volume with slack');

    # Hercules form: exact length, high cylinder 0 -> gets the cylinder count
    truncate($vol, 512 + 1113 * $cyl);
    PVE::QemuServer::DASD::write_image_head($vol, 'raw', $hercules);
    $checked = PVE::QemuServer::DASD::check_ckd_volume({}, 'x');
    is($checked->{'high-cylinder'}, 1113, 'Hercules header completed');
    is(
        substr(PVE::QemuServer::DASD::read_image_head($vol, 'raw'), 0, 32),
        'CKD_P370' . substr($header, 8, 10) . pack('v', 1113) . '876955967561',
        'identifier and serial kept',
    );

    # import of a Hercules image (exact length, high cylinder 0) into storage that rounds the
    # size up: 4 MiB LVM extents, 16 KiB ZFS volblocksize
    for my $rounding ([lvm => 4 * 1024 * 1024], [zfs => 16 * 1024]) {
        my ($what, $unit) = $rounding->@*;
        my $source_size = 512 + 1113 * $cyl;
        my $source_header = $parse->($hercules, $source_size);
        is($source_header->{cylinders}, 1113, "$what: source cylinders");
        # the copy of the source, on a volume with slack
        truncate($vol, 0);
        truncate($vol, $source_size + ($unit - $source_size % $unit) % $unit);
        PVE::QemuServer::DASD::write_image_head($vol, 'raw', $hercules);
        ok(-s $vol > $source_size, "$what: destination has slack");
        like(
            (eval { PVE::QemuServer::DASD::check_ckd_volume({}, 'x') } // $@),
            qr/whole cylinders/,
            "$what: the slack alone does not tell the cylinders",
        );
        my $imported = PVE::QemuServer::DASD::finish_ckd_import({}, 'x', $source_header);
        is($imported->{cylinders}, 1113, "$what: imported volume has the source cylinders");
        is(
            $parse->(PVE::QemuServer::DASD::read_image_head($vol, 'raw'), -s $vol)->{cylinders},
            1113,
            "$what: cylinder count written into the header",
        );
    }
    truncate($vol, 512 + 1000 * $cyl);
    eval {
        PVE::QemuServer::DASD::finish_ckd_import(
            {}, 'x', { cylinders => 1113, 'high-cylinder' => 0 },
        );
    };
    like($@, qr/too small for 1113 cylinders/, 'import destination too small');

    # live migration with storage migration: the header of the source volume (Hercules form here)
    # for the new, larger volume on the target
    truncate($vol, 0);
    truncate($vol, 512 + 1113 * $cyl);
    PVE::QemuServer::DASD::write_image_head($vol, 'raw', $hercules);
    my $migration_header = PVE::QemuServer::DASD::ckd_volume_header_for_migration({}, 'x');
    is(length($migration_header), 512, 'migration: header length');
    is($parse->($migration_header, 10**12)->{'high-cylinder'}, 1113, 'migration: cylinder count');
    is(substr($migration_header, 20, 12), '876955967561', 'migration: serial kept');
    truncate($vol, 0);
    truncate($vol, 512 + 1113 * $cyl + 4 * 1024 * 1024);
    my $target = PVE::QemuServer::DASD::init_ckd_volume_from_header({}, 'x', $migration_header);
    is($target->{cylinders}, 1113, 'migration: new volume initialized');
    is(
        PVE::QemuServer::DASD::read_image_head($vol, 'raw'),
        $migration_header,
        'migration: header of the source on the new volume',
    );
    is(
        PVE::QemuServer::DASD::ckd_volume_header_for_migration({}, 'x'),
        $migration_header,
        'migration: header with cylinder count taken as is',
    );
    truncate($vol, 512 + 1000 * $cyl);
    eval { PVE::QemuServer::DASD::init_ckd_volume_from_header({}, 'x', $migration_header) };
    like($@, qr/too short for 1113 cylinders/, 'migration: new volume too small');
    eval { PVE::QemuServer::DASD::init_ckd_volume_from_header({}, 'x', $hercules) };
    like($@, qr/no cylinder count/, 'migration: header without cylinder count refused');
}

# the model of a DASD in the config
for my $test (
    ['ckd0', { interface => 'ckd', cylinders => 10017 }, '3390-9'],
    ['ckd0', { interface => 'ckd', cylinders => 3339 }, '3390-3'],
    ['ckd0', { interface => 'ckd', cylinders => 5000 }, '3390'],
    ['ckd0', { interface => 'ckd', cylinders => 10017, model => '3390' }, '3390'],
    ['ckd0', { interface => 'ckd', cylinders => 10017, model => '3390-3' }, qr/a 3390-3 has 3339/],
    ['ckd0', { interface => 'ckd' }, undef],
    ['fba0', { interface => 'fba' }, '9336'],
) {
    my ($key, $drive, $expected) = $test->@*;
    my $name = join(',', map { "$_=$drive->{$_}" } sort keys %$drive);
    eval { PVE::QemuServer::DASD::set_drive_model($key, $drive) };
    if (ref($expected)) {
        like($@, $expected, "model of $name refused");
    } else {
        is($@, '', "model of $name");
        is($drive->{model}, $expected, "model of $name");
    }
}
is(
    PVE::QemuServer::DASD::ckd_cylinders_of_drive({ model => '3390', cylinders => 5000 }),
    5000,
    'generic 3390 model with cylinders',
);
eval { PVE::QemuServer::DASD::ckd_cylinders_of_drive({ model => '3390' }) };
like($@, qr/need 'model' or 'cylinders'/, 'generic 3390 model needs cylinders');
{
    my $drive = PVE::QemuServer::Drive::parse_drive(
        'ckd0', 'local-lvm:vm-300-SYSRS1,cylinders=10017,devno=0.0.0300,model=3390-9,size=8G',
    );
    is($drive->{model}, '3390-9', 'model parsed from the config');
    is(
        PVE::QemuServer::Drive::print_drive($drive),
        'local-lvm:vm-300-SYSRS1,cylinders=10017,devno=0.0.0300,model=3390-9,size=8G',
        'model printed into the config',
    );
    ok(
        !PVE::QemuServer::Drive::parse_drive('fba0', 'local:1,model=3390-9'),
        'an FBA DASD is no 3390',
    );
    my $ide = PVE::QemuServer::Drive::parse_drive('ide0', 'local:1,model=My%20Disk');
    is(PVE::QemuServer::Drive::print_drive($ide), 'local:1,model=My%20Disk', 'IDE model kept');
}

# identity override: needs the QEMU properties
{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    my $props = {};
    $helpers->mock(
        get_command_for_arch => sub { '/usr/bin/kvm' },
        kvm_device_has_property => sub { $props->{"$_[1].$_[2]"} ? 1 : 0 },
    );
    my $drive = { interface => 'ckd', devtype => '3380-0e', cutype => '3990' };
    my $named = { interface => 'ckd', devtype => '3380-K', cutype => '3990-6' };
    eval { PVE::QemuServer::DASD::identity_properties('ckd0', $drive, 's390x') };
    like($@, qr/^ckd0: 'cutype' needs a QEMU with the 'control-unit-type' property/, 'no QEMU support');
    $props = { map { $_ => 1 } qw(eckd-ccw.device-type eckd-ccw.control-unit-type) };
    is(
        PVE::QemuServer::DASD::identity_properties('ckd0', $drive, 's390x'),
        ',control-unit-type=' . 0x3990 . ',device-type=' . 0x3380 . ',device-model=14',
        'identity properties',
    );
    is(
        PVE::QemuServer::DASD::identity_properties('ckd0', $named, 's390x'),
        ',control-unit-type=' . 0x3990 . ',control-unit-model=' . 0xe9
            . ',device-type=' . 0x3380 . ',device-model=' . 0x1e,
        'identity properties of model names',
    );
    is(PVE::QemuServer::DASD::identity_properties('ckd0', { interface => 'ckd' }, 's390x'), '',
        'no identity override');
}

# identity syntax TTTT[-MM]: model names of the usual designations or the Sense ID model byte in hex
# (3380-K and 3990-6 were refused)
for my $test (
    ['3380', 0x3380, undef],
    ['3380-K', 0x3380, 0x1e],
    ['3380-k', 0x3380, 0x1e],
    ['3380-E', 0x3380, 0x0a],
    ['3380-J', 0x3380, 0x02],
    ['3380-1e', 0x3380, 0x1e],
    ['3390-9', 0x3390, 0x0c],
    ['3390-3', 0x3390, 0x0a],
    ['3390-27', 0x3390, 0x0c], # the name, not the byte 0x27
    ['3390-0c', 0x3390, 0x0c],
    ['3990-6', 0x3990, 0xe9],
    ['3990-ec', 0x3990, 0xec],
    ['2107-E8', 0x2107, 0xe8],
    ['9336-10', 0x9336, 0x10],
) {
    my ($value, $type, $model) = @$test;
    is_deeply([PVE::QemuServer::Drive::parse_dasd_identity($value)], [$type, $model], "identity $value");
}
for my $test (
    ['3380-X', qr/^unknown model 'X' of 3380, expected A, D, E, J, K or the model byte/],
    ['3390-5', qr/^unknown model '5' of 3390/],
    ['3380-00', qr/model byte 00 means 'derive'/],
    ['338', qr/^invalid identity/],
    ['3380-ABC', qr/^invalid identity/],
    ['9336-Z', qr/^unknown model 'Z' of 9336, expected the model byte in hex/],
) {
    my ($value, $re) = @$test;
    eval { PVE::QemuServer::Drive::parse_dasd_identity($value) };
    like($@, $re, "identity $value refused");
}
{
    my $drive = PVE::QemuServer::Drive::parse_drive('ckd0', 'local:1,devtype=3380-K,cutype=3990-6');
    ok($drive, 'drive with devtype=3380-K,cutype=3990-6 parses');
    ok(!PVE::QemuServer::Drive::parse_drive('ckd0', 'local:1,devtype=3380-X'), 'unknown model refused');
}

# names of DASD volumes kept on import, restore and migration
for my $test (
    ['local-lvm:vm-300-SYSRS1', 'SYSRS1'],
    ['local:300/vm-300-WORK01.qcow2', 'WORK01'],
    ['local-zfs:vm-300-disk-0', undef],
    ['local:300/vm-300-cloudinit.qcow2', undef],
    ['local:import/x.raw', undef],
    ['rbd:vm-1234-WORK_02', 'WORK_02'],
) {
    my ($volid, $expected) = @$test;
    is(PVE::QemuServer::DASD::volume_name_of_volid($volid), $expected, "volume name of $volid");
}
for my $test (
    ['local:import/SYSRS1.ckd', 'SYSRS1'],
    ['local:import/sysrs1.FBA', 'sysrs1'],
    ['/mnt/hercules/dasd/SYSRES.ckd64', 'SYSRES'],
    ['local:import/mf01.ova/mf01-ckd0.vmdk', undef],
    ['local:import/disk.qcow2', undef],
    ['local-lvm:vm-300-SYSRS1', 'SYSRS1'],
    ['local:import/bad name.ckd', undef],
) {
    my ($source, $expected) = @$test;
    is(
        PVE::QemuServer::DASD::import_source_volume_name($source),
        $expected,
        "import volume name of $source",
    );
}
{
    my $storage = Test::MockModule->new('PVE::Storage');
    my $taken = { 'vm-301-SYSRS1' => 1 };
    my @calls;
    $storage->mock(
        storage_config => sub { return { type => 'lvmthin' } },
        vdisk_alloc => sub {
            my ($cfg, $storeid, $vmid, $fmt, $name, $size) = @_;
            push @calls, $name // 'undef';
            die "volume '$name' already exists\n" if defined($name) && $taken->{$name};
            return "$storeid:" . ($name // "vm-$vmid-disk-0");
        },
    );
    is(
        PVE::QemuServer::DASD::alloc_named_volume({}, 'local-lvm', 301, 'raw', 'WORK01', 1, 'ckd1'),
        'local-lvm:vm-301-WORK01',
        'free name kept',
    );
    my $warning = '';
    local $SIG{__WARN__} = sub { $warning .= $_[0] };
    is(
        PVE::QemuServer::DASD::alloc_named_volume({}, 'local-lvm', 301, 'raw', 'SYSRS1', 1, 'ckd0'),
        'local-lvm:vm-301-disk-0',
        'taken name: default name',
    );
    like($warning, qr/ckd0: unable to allocate the volume 'vm-301-SYSRS1'.*default volume name/,
        'taken name: warning');
}

# zPDT images: file sequence 0x04 and a cylinder count
my $zpdt = $header;
substr($zpdt, 17, 1, "\x04");
is($parse->($zpdt, 512 + 3339 * $cyl)->{'file-sequence'}, 4, 'zPDT: file sequence');
is($parse->($zpdt, 512 + 3339 * $cyl)->{cylinders}, 3339, 'zPDT: exact length');
like($parse->($zpdt, 512 + 3339 * $cyl + 16384), qr/whole cylinders/, 'zPDT: slack refused');
is(
    eval { PVE::QemuServer::DASD::parse_ckd_header($zpdt, 512 + 3339 * $cyl + 16384, 1) }
        ->{cylinders},
    3339,
    'zPDT: slack allowed for the source of a copy',
);
like(
    (eval { PVE::QemuServer::DASD::parse_ckd_header($multi, 512 + 10000 * $cyl, 1) } // $@),
    qr/multi-file/,
    'multi-file member is no image with slack',
);
ok(PVE::QemuServer::DASD::ckd_image_needs_exact_size({ 'file-sequence' => 4 }), 'zPDT: exact size');
ok(!PVE::QemuServer::DASD::ckd_image_needs_exact_size({ 'file-sequence' => 0 }), 'Hercules: slack ok');
{
    local $slack_supported = 1;
    ok(
        !PVE::QemuServer::DASD::ckd_image_needs_exact_size({ 'file-sequence' => 4 }),
        'zPDT with a QEMU-mod that accepts slack',
    );
    is($parse->($zpdt, 512 + 3339 * $cyl + 16384)->{cylinders}, 3339, 'zPDT: slack accepted');
    like($parse->($zpdt, 512 + 3338 * $cyl), qr/too short/, 'zPDT: shorter still refused');
}
is(
    substr(PVE::QemuServer::DASD::ckd_header(3339, '876955967561', 'CKD_P064', 4), 0, 32),
    substr($zpdt, 0, 32),
    'header with a file sequence',
);

{
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(storage_config => sub { return $_[0]->{ $_[1] } });
    my $storecfg = {
        local => { type => 'dir', path => '/var/lib/vz' },
        'local-zfs' => { type => 'zfspool' },
        lvm => { type => 'lvm', 'snapshot-as-volume-chain' => 1 },
    };
    ok(PVE::QemuServer::DASD::storage_has_exact_size($storecfg, 'local', 'qcow2'), 'dir: exact');
    ok(!PVE::QemuServer::DASD::storage_has_exact_size($storecfg, 'local', 'vmdk'), 'vmdk: no');
    ok(!PVE::QemuServer::DASD::storage_has_exact_size($storecfg, 'local-zfs', 'raw'), 'zvol: no');
    ok(!PVE::QemuServer::DASD::storage_has_exact_size($storecfg, 'lvm', 'qcow2'), 'chain: no');
    my $zpdt_header = $parse->($zpdt, 512 + 3339 * $cyl);
    eval {
        PVE::QemuServer::DASD::assert_ckd_target_storage(
            $storecfg, 'local', 'raw', $zpdt_header, 'ckd0',
        );
    };
    is($@, '', 'zPDT image to a directory storage');
    eval {
        PVE::QemuServer::DASD::assert_ckd_target_storage(
            $storecfg, 'local-zfs', 'raw', $zpdt_header, 'ckd0',
        );
    };
    like(
        $@,
        qr/^ckd0: the CKD image needs a volume of exactly 2846431232 bytes .* file sequence 0x04 .*'local-zfs' \(zfspool\) rounds the size up.*file based storage/,
        'zPDT image to a zvol refused',
    );
    eval {
        PVE::QemuServer::DASD::assert_ckd_target_storage(
            $storecfg, 'local-zfs', 'raw', $parse->($header, 512 + 3339 * $cyl), 'ckd0',
        );
    };
    is($@, '', 'Hercules image to a zvol');
    {
        local $slack_supported = 1;
        eval {
            PVE::QemuServer::DASD::assert_ckd_target_storage(
                $storecfg, 'local-zfs', 'raw', $zpdt_header, 'ckd0',
            );
        };
        is($@, '', 'zPDT image to a zvol, QEMU-mod accepts slack');
    }
}

is(
    PVE::QemuServer::DASD::image_opts_cut('/dev/zvol/rpool/vm-1-disk-0', 'raw', 512),
    'driver=raw,offset=0,size=512,file.driver=file,file.filename=/dev/zvol/rpool/vm-1-disk-0',
    'cut image options, raw',
);
is(
    PVE::QemuServer::DASD::image_opts_cut('/var/lib/vz/images/1/a.qcow2', 'qcow2', 1024),
    'driver=raw,offset=0,size=1024,file.driver=qcow2,file.file.driver=file,'
        . 'file.file.filename=/var/lib/vz/images/1/a.qcow2',
    'cut image options, qcow2',
);
like(
    (eval { PVE::QemuServer::DASD::image_opts_cut('rbd:pool/x', 'raw', 512) } // $@),
    qr/not a local file/,
    'cut image options: local paths only',
);

# the VOLSER from the volume label (record 3 of track 0)
{
    my %e = (map { (chr(ord('A') + $_) => 0xc1 + $_) } 0 .. 8);
    $e{ chr(ord('J') + $_) } = 0xd1 + $_ for 0 .. 8;
    $e{ chr(ord('S') + $_) } = 0xe2 + $_ for 0 .. 7;
    $e{ chr(ord('0') + $_) } = 0xf0 + $_ for 0 .. 9;
    $e{' '} = 0x40;
    $e{'@'} = 0x7c;
    my $ebcdic = sub { join('', map { chr($e{$_}) } split(//, $_[0])) };
    my $track = sub {
        my ($volser) = @_;
        my $t = pack('C n n', 0, 0, 0);
        $t .= pack('n n C C n', 0, 0, 0, 0, 8) . ("\0" x 8); # R0
        $t .= pack('n n C C n', 0, 0, 1, 4, 24) . $ebcdic->('IPL1') . ("\0" x 24);
        $t .= pack('n n C C n', 0, 0, 2, 4, 144) . $ebcdic->('IPL2') . ("\0" x 144);
        $t .= pack('n n C C n', 0, 0, 3, 4, 80)
            . $ebcdic->('VOL1')
            . $ebcdic->('VOL1')
            . $ebcdic->($volser)
            . ("\0" x 70);
        return $header . $t . ("\xff" x 8);
    };
    is(PVE::QemuServer::DASD::ckd_volser($track->('RES001')), 'RES001', 'VOLSER');
    is(PVE::QemuServer::DASD::ckd_volser($track->('WORK  ')), 'WORK', 'short VOLSER');
    is(PVE::QemuServer::DASD::ckd_volser($track->('SYS@01')), undef, 'national character: none');
    is(PVE::QemuServer::DASD::ckd_volser($header . ("\0" x 1024)), undef, 'unformatted: none');
    is(PVE::QemuServer::DASD::ckd_volser(substr($track->('RES001'), 0, 600)), undef, 'cut: none');

    $dasd->mock(read_image_head => sub { return $track->('SYS001') });
    my $source =
        PVE::QemuServer::DASD::check_ckd_import_source('/x.3390', 'raw', 512 + 3339 * $cyl);
    is($source->{volser}, 'SYS001', 'CKD import source: VOLSER');
    $dasd->unmock('read_image_head');
}

# cutting the slack of copied volumes, with the real tools
SKIP: {
    skip 'qemu-img/qemu-io not installed', 10 if !-x '/usr/bin/qemu-img' || !-x '/usr/bin/qemu-io';

    my $dir = tempdir(CLEANUP => 1);
    my $vol;
    my $format;
    my $storeid = 'local';
    my $storecfg = {
        local => { type => 'dir', path => $dir, content => { images => 1 } },
        'local-zfs' => { type => 'zfspool', content => { images => 1 } },
    };
    my $storage = Test::MockModule->new('PVE::Storage');
    $storage->mock(
        activate_volumes => sub { },
        path => sub { return $vol },
        parse_volname => sub { return ('images', 'x', 100, undef, undef, undef, $format) },
        volume_size_info => sub {
            my $info = '';
            PVE::Tools::run_command(
                ['/usr/bin/qemu-img', 'info', '--output=json', '-f', $format, $vol],
                outfunc => sub { $info .= shift },
            );
            return JSON::decode_json($info)->{'virtual-size'};
        },
        parse_volume_id => sub { return ($storeid, 'x') },
        storage_config => sub { return $_[0]->{ $_[1] } },
    );
    my $exact = 512 + 1113 * $cyl;
    my $zpdt_1113 = PVE::QemuServer::DASD::ckd_header(1113, '000000000001', 'CKD_P064', 4);
    for my $f (qw(raw qcow2)) {
        $format = $f;
        $vol = "$dir/zpdt.$f";
        PVE::Tools::run_command(
            ['/usr/bin/qemu-img', 'create', '-f', $f, $vol, $exact + 16384],
            outfunc => sub { },
        );
        PVE::QemuServer::DASD::write_image_head($vol, $f, $zpdt_1113);
        my $source = PVE::QemuServer::DASD::ckd_copy_source_header($storecfg, 'x');
        is($source->{cylinders}, 1113, "$f: copy source with slack");
        my $res = PVE::QemuServer::DASD::finish_ckd_import($storecfg, 'x', $source);
        is($res->{size}, $exact, "$f: slack cut on file based storage");
        is(
            PVE::QemuServer::DASD::check_ckd_volume($storecfg, 'x')->{cylinders},
            1113,
            "$f: volume usable",
        );
        is(PVE::QemuServer::DASD::read_image_head($vol, $f), $zpdt_1113, "$f: header unchanged");
    }
    # a zvol: the slack stays, QEMU-mod up to +s390x9 refuses it
    $storeid = 'local-zfs';
    $format = 'raw';
    $vol = "$dir/zvol.raw";
    PVE::Tools::run_command(
        ['/usr/bin/qemu-img', 'create', '-f', 'raw', $vol, $exact + 16384],
        outfunc => sub { },
    );
    PVE::QemuServer::DASD::write_image_head($vol, 'raw', $zpdt_1113);
    my $source = PVE::QemuServer::DASD::ckd_copy_source_header($storecfg, 'x');
    eval { PVE::QemuServer::DASD::finish_ckd_import($storecfg, 'x', $source) };
    like($@, qr/rounds the size up/, 'zvol with slack refused');
    like(
        (eval { PVE::QemuServer::DASD::check_ckd_volume($storecfg, 'x') } // $@),
        qr/needs a volume of exactly $exact bytes.*move it to a file based storage/,
        'attaching a zvol with slack: what to do',
    );
}

# the cylinders of a CKD volume for QEMU-mod builds with the property
{
    my $helpers = Test::MockModule->new('PVE::QemuServer::Helpers');
    my $props = {};
    $helpers->mock(
        get_command_for_arch => sub { return '/usr/bin/qemu-system-s390x' },
        kvm_device_has_property => sub { return $props->{"$_[1].$_[2]"} ? 1 : 0 },
    );
    my $drive = { interface => 'ckd', cylinders => 10017 };
    is(PVE::QemuServer::DASD::identity_properties('ckd0', $drive, 's390x'), '', 'no cylinders');
    $props->{'eckd-ccw.cylinders'} = 1;
    is(
        PVE::QemuServer::DASD::identity_properties('ckd0', $drive, 's390x'),
        ',cylinders=10017',
        'cylinders for QEMU',
    );
}

# volumes allocated in the order of the drives
is_deeply(
    [PVE::QemuServer::Drive::sort_drive_keys(qw(ckd10 ckd2 fba1 ckd0 ckd1 efidisk0 name))],
    [qw(ckd0 ckd1 ckd2 ckd10 efidisk0 fba1 name)],
    'drive keys by interface and index',
);

# the size of the disk an s390x VM IPLs from
is(
    PVE::QemuServer::Drive::bootdisk_size(
        {},
        {
            ipl => 'ckd1,loadparm=0A82DC',
            ckd0 => 'local:500/vm-500-SYS001.qcow2,devno=0a80,size=100',
            ckd1 => 'local:500/vm-500-RES001.qcow2,devno=0a81,size=8539292672',
        },
    ),
    8539292672,
    'IPL disk size',
);

done_testing();
