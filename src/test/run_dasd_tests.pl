#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;

use PVE::QemuServer::DASD;
use PVE::QemuServer::Drive;
use PVE::QemuServer::Helpers;
use PVE::QemuServer::IPL;
use PVE::QemuMigrate::Helpers;

my $cyl = 852480;

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
my $dasd = Test::MockModule->new('PVE::QemuServer::DASD');
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
ok(!PVE::QemuServer::Drive::parse_drive('ckd0', 'local:0,model=3390-9'), 'model only on alloc');
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

    # a volume through the storage layer: create, attach a Hercules image, resize
    my $vol = "$dir/vm-100-SYSRS1.raw";
    $storage->mock(
        activate_volumes => sub { },
        path => sub { return $vol; },
        parse_volname =>
            sub { return ('images', 'vm-100-SYSRS1.raw', 100, undef, undef, undef, 'raw'); },
        volume_size_info => sub { return -s $vol; },
        volume_resize => sub {
            my ($cfg, $volid, $size) = @_;
            truncate($vol, $size + (1024 - $size % 1024) % 1024) or die "truncate: $!\n";
        },
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

    # grow by 1 GiB: 1259 cylinders
    my ($size, $cylinders) =
        PVE::QemuServer::DASD::resize_ckd_volume({}, 'x', undef, 1024 * 1024 * 1024);
    is($cylinders, 1113 + 1259, 'grown by whole cylinders');
    is($size, -s $vol, 'new size');
    ok($size >= PVE::QemuServer::DASD::ckd_volume_size(2372), 'large enough');
    eval { PVE::QemuServer::DASD::resize_ckd_volume({}, 'x', undef, 852479) };
    like($@, qr/grows by whole cylinders/, 'less than a cylinder');
    ($size, $cylinders) = PVE::QemuServer::DASD::resize_ckd_volume({}, 'x', 10**12, undef);
    is($cylinders, 65520, 'at most 65520 cylinders');

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

done_testing();
