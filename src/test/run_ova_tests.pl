#!/usr/bin/perl

# Tests of the OVA export (PVE::QemuServer::OVA): the OVF descriptor of an s390x mainframe VM and of
# an x86_64 VM, and an export of real (small) images, which must keep the disk content byte for
# byte in every disk format.

use v5.36;

use lib qw(..);

use Digest::SHA;
use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;
use XML::LibXML;

use PVE::Tools qw(run_command);

use PVE::QemuServer::DASD;
use PVE::QemuServer::OVA;

my $expected_dir = 'ova';

my $mf_conf = {
    boot => 'order=ckd0;net0',
    ckd0 => 'local-lvm:vm-300-SYSRS1,cylinders=10017,devno=0.0.0200,size=8339153K',
    ckd1 => 'local:300/vm-300-WORK01.qcow2,cylinders=10017,devno=0.0.0201,size=8339153K',
    ckd2 => 'local-lvm:vm-300-WORK02,cylinders=10017,devno=0.0.0202,size=8339153K',
    ipl => 'ckd0',
    machine => 'mtm-3907',
    memory => 2048,
    meta => 'creation-qemu=11.1.90,ctime=1795037352',
    name => 'mf01',
    net0 => 'qeth=BC:24:11:6C:CE:D6,bridge=vmbr1,devno=0.0.0400',
    ostype => 'other',
    smbios1 => 'uuid=16b025dd-9027-43f8-88e8-42b1b670e92c',
    tape0 => 'local:iso/SYSTEM.AWS',
    terminal0 => '0.0.0300',
    terminal1 => '0.0.0301',
    terminal2 => '0.0.0302',
    vmgenid => 'd1bb1037-5a5d-4d17-885e-048440163fc3',
};

my $linux_conf = {
    bios => 'ovmf',
    boot => 'order=scsi0;ide2;net0',
    cores => 2,
    cpu => 'x86-64-v2-AES',
    efidisk0 => 'local-lvm:vm-101-disk-0,efitype=4m,size=4M',
    ide2 => 'local:iso/debian.iso,media=cdrom',
    memory => 4096,
    name => 'deb',
    net0 => 'virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1,tag=10',
    hookscript => 'local:snippets/hook.pl',
    args => '-foo',
    ostype => 'l26',
    scsi0 => 'local-lvm:vm-101-disk-1,discard=on,iothread=1,size=32G',
    scsihw => 'virtio-scsi-single',
    serial0 => 'socket',
    sockets => 1,
    tpmstate0 => 'local-lvm:vm-101-disk-2,size=4M,version=v2.0',
    virtio1 => 'local:101/vm-101-disk-3.qcow2,size=1G',
};

sub parse_conf_drives($conf) {
    my ($disks, $warnings) = PVE::QemuServer::OVA::export_disks($conf);
    my $i = 0;
    for my $disk (@$disks) {
        $disk->{href} = "x-$disk->{key}.vmdk";
        $disk->{file_size} = 1000 + $i++;
        $disk->{capacity} = $disk->{drive}->{size} // 0;
        $disk->{format} = 'vmdk';
    }
    return ($disks, $warnings);
}

sub xpc_of($xml) {
    my $dom = XML::LibXML->load_xml(string => $xml);
    my $xpc = XML::LibXML::XPathContext->new($dom);
    $xpc->registerNs('ovf', 'http://schemas.dmtf.org/ovf/envelope/1');
    $xpc->registerNs(
        'rasd',
        'http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData',
    );
    $xpc->registerNs('pve', 'http://www.proxmox.com/schema/ovf');
    return $xpc;
}

my sub compare_expected($name, $got) {
    my $file = "$expected_dir/$name";
    if ($ENV{OVA_TEST_UPDATE}) {
        PVE::Tools::file_set_contents($file, $got);
    }
    my $expected = -f $file ? PVE::Tools::file_get_contents($file) : '';
    is($got, $expected, "descriptor $name matches the expected one");
}

# s390x mainframe VM
{
    my ($disks, $warnings) = parse_conf_drives($mf_conf);
    is_deeply([map { $_->{key} } @$disks], [qw(ckd0 ckd1 ckd2)], 'mf01: exported disks');
    is_deeply($warnings, [], 'mf01: nothing left out');

    my $xml = PVE::QemuServer::OVA::ovf_descriptor(300, $mf_conf, $disks, 's390x');
    compare_expected('mf01.ovf', $xml);
    my $xpc = xpc_of($xml);

    is($xpc->findvalue('//ovf:VirtualSystem/ovf:Name'), 'mf01', 'mf01: name');
    is($xpc->findvalue('//ovf:OperatingSystemSection/@ovf:id'), '1', 'mf01: OS type Other');
    my @disk_items = $xpc->findnodes('//ovf:Item[rasd:ResourceType=17]');
    is(scalar(@disk_items), 3, 'mf01: three disk items');
    is($xpc->findvalue('rasd:ResourceSubType', $disk_items[0]), '3390-9', 'mf01: ckd0 is a 3390-9');
    is($xpc->findvalue('rasd:Address', $disk_items[0]), '0.0.0200', 'mf01: ckd0 device number');
    is(
        $xpc->findvalue('rasd:AddressOnParent', $disk_items[2]),
        '2',
        'mf01: DASDs numbered on their controller',
    );
    my $parent = $xpc->findvalue('rasd:Parent', $disk_items[0]);
    is(
        $xpc->findvalue("//ovf:Item[rasd:InstanceID='$parent']/rasd:ResourceType"),
        '20',
        'mf01: DASD controller is an other storage device (SATA for generic importers)',
    );
    is(
        $xpc->findvalue('//ovf:Item[rasd:ResourceType=10]/rasd:ResourceSubType'),
        'qeth',
        'mf01: qeth adapter',
    );
    is(
        $xpc->findvalue('//ovf:Item[rasd:ResourceType=10]/rasd:Address'),
        'BC:24:11:6C:CE:D6',
        'mf01: MAC address',
    );
    my @tapes = $xpc->findnodes('//ovf:Item[rasd:ResourceType=18]');
    is(scalar(@tapes), 1, 'mf01: one tape drive');
    is($tapes[0]->getAttribute('ovf:required'), 'false', 'mf01: tape drive not required');
    is($xpc->findvalue('rasd:Address', $tapes[0]), '0.0.0580', 'mf01: tape default devno');
    my @terms = $xpc->findnodes('//ovf:Item[rasd:ResourceType=1]');
    is(scalar(@terms), 3, 'mf01: three 3270 terminals');
    is($xpc->findvalue('rasd:Address', $terms[1]), '0.0.0301', 'mf01: terminal1 devno');

    my $pve = { map { $_->getAttribute('pve:key') => $_ } $xpc->findnodes('//pve:Config') };
    is_deeply(
        [sort keys %$pve],
        [
            sort qw(boot ckd0 ckd1 ckd2 ipl machine memory net0 ostype tape0 terminal0
                terminal1 terminal2)
        ],
        'mf01: Proxmox VE section entries',
    );
    is(
        $pve->{ckd0}->getAttribute('pve:value'),
        'cylinders=10017,devno=0.0.0200',
        'mf01: ckd0 options without volume and size',
    );
    is($pve->{ckd0}->getAttribute('pve:diskId'), 'ckd0', 'mf01: ckd0 refers to its disk');
    is($pve->{machine}->getAttribute('pve:value'), 'mtm-3907', 'mf01: machine type');
    is(
        $xpc->findvalue('//pve:ConfigSection/@pve:arch'), 's390x', 'mf01: section architecture',
    );
}

# x86_64 VM: EFI, TPM, CD-ROM, VirtIO, hookscript and args
{
    my ($disks, $warnings) = parse_conf_drives($linux_conf);
    is_deeply([map { $_->{key} } @$disks], [qw(scsi0 virtio1)], 'Linux: exported disks');
    is(scalar(@$warnings), 2, 'Linux: EFI vars and TPM state not exported');

    my $xml = PVE::QemuServer::OVA::ovf_descriptor(101, $linux_conf, $disks, 'x86_64');
    compare_expected('linux-x86_64.ovf', $xml);
    my $xpc = xpc_of($xml);

    is($xpc->findvalue('//ovf:OperatingSystemSection/@ovf:id'), '101', 'Linux: OS type');
    is(
        $xpc->findvalue(
            '//*[local-name()="Config" and @*[local-name()="key"]="firmware"]/@*[local-name()="value"]'
        ),
        'efi',
        'Linux: EFI firmware for generic importers',
    );
    my @keys = map { $_->getAttribute('pve:key') } $xpc->findnodes('//pve:Config');
    ok(
        !(grep { $_ eq 'hookscript' || $_ eq 'args' || $_ eq 'efidisk0' } @keys),
        'Linux: no hookscript, args or EFI disk in the Proxmox VE section',
    );
    ok((grep { $_ eq 'serial0' } @keys), 'Linux: socket serial port kept');
    is(
        $xpc->findvalue('//pve:Config[@pve:key="boot"]/@pve:value'),
        'order=scsi0;net0',
        'Linux: boot order without the CD-ROM drive',
    );
    is(
        $xpc->findvalue('//ovf:Item[rasd:ResourceType=6]/rasd:ResourceSubType'),
        'virtio-scsi-single',
        'Linux: SCSI controller type',
    );
}

# names
is(PVE::QemuServer::OVA::ova_name(300, $mf_conf), 'mf01', 'OVA name from the VM name');
is(PVE::QemuServer::OVA::ova_name(300, {}), 'vm300', 'OVA name without VM name');
is(PVE::QemuServer::OVA::ova_name(300, {}, 'x.ova'), 'x', 'OVA name given with .ova');
eval { PVE::QemuServer::OVA::ova_name(300, {}, '../x') };
like($@, qr/invalid OVA file name/, 'OVA name with a path refused');

# export of real images
SKIP: {
    skip 'no qemu-img', 1 if !-x '/usr/bin/qemu-img';

    my $dir = tempdir(CLEANUP => 1);
    my $import_dir = "$dir/import";

    # a 10 cylinder CKD volume (raw), with data in some tracks, and an FBA volume (qcow2)
    my $ckd = "$dir/vm-900-disk-0.raw";
    my $cylinders = 10;
    my $size = PVE::QemuServer::DASD::ckd_volume_size($cylinders);
    open(my $fh, '>', $ckd) or die "$ckd: $!\n";
    print $fh PVE::QemuServer::DASD::ckd_header($cylinders, '123456789012');
    truncate($fh, $size + 4 * 1024 * 1024); # with slack, like block storage
    for my $track (0, 1, 37, 149) {
        seek($fh, 512 + $track * 56832, 0);
        print $fh pack('C*', map { ($track + $_) % 256 } 0 .. 4999);
    }
    close($fh);
    my $fba_raw = "$dir/fba.raw";
    open($fh, '>', $fba_raw) or die;
    print $fh 'FBA!' x 1024;
    truncate($fh, 1024 * 1024);
    close($fh);
    my $fba = "$dir/vm-900-disk-1.qcow2";
    run_command(['/usr/bin/qemu-img', 'convert', '-f', 'raw', '-O', 'qcow2', $fba_raw, $fba]);

    my $conf = {
        name => 'export-test',
        machine => 'mtm-3907',
        ostype => 'other',
        memory => 512,
        ipl => 'ckd0',
        ckd0 => "local:900/vm-900-disk-0.raw,cylinders=$cylinders,devno=0.0.0300",
        fba0 => 'local:900/vm-900-disk-1.qcow2,devno=0.0.0200',
        terminal0 => '0.0.0700',
    };
    my $written_conf = {%$conf};
    my $paths = {
        'local:900/vm-900-disk-0.raw' => [$ckd, 'raw', -s $ckd],
        'local:900/vm-900-disk-1.qcow2' => [$fba, 'qcow2', 1024 * 1024],
    };

    my $config_module = Test::MockModule->new('PVE::QemuConfig');
    $config_module->mock(
        load_config => sub { return {%$written_conf} },
        lock_config => sub($class, $vmid, $code) { return $code->() },
        write_config => sub($class, $vmid, $c) { $written_conf = {%$c} },
        check_lock => sub { die "VM is locked\n" if $_[1]->{lock} },
    );
    my $helpers_module = Test::MockModule->new('PVE::QemuServer::Helpers');
    $helpers_module->mock(vm_running_locally => sub { 0 });
    my $drive_module = Test::MockModule->new('PVE::QemuServer::Drive');
    $drive_module->mock(checked_volume_format => sub { $paths->{ $_[1] }->[1] });
    my $storage_module = Test::MockModule->new('PVE::Storage');
    $storage_module->mock(
        storage_config => sub { { type => 'dir', path => $dir, content => { import => 1 } } },
        activate_storage => sub { },
        get_import_dir => sub { $import_dir },
        activate_volumes => sub { },
        path => sub { $paths->{ $_[1] }->[0] },
        volume_size_info => sub { $paths->{ $_[1] }->[2] },
    );

    for my $format (@{ PVE::QemuServer::OVA::disk_formats() }) {
        my $volid = eval {
            PVE::QemuServer::OVA::export_ova(
                {},
                900,
                'local',
                {
                    format => $format,
                    filename => "test-$format",
                },
            );
        };
        is($@, '', "export ($format)");
        is($volid, "local:import/test-$format.ova", "export ($format): volume ID");
        ok(!defined($written_conf->{lock}), "export ($format): lock removed");
        my $ova = "$import_dir/test-$format.ova";

        my $members = '';
        run_command(['tar', '-tf', $ova], outfunc => sub { $members .= "$_[0]\n" });
        is(
            $members,
            join('',
                map { "$_\n" } "test-$format.ovf",
                "test-$format.mf",
                "test-$format-ckd0.$format",
                "test-$format-fba0.$format"),
            "export ($format): archive members in OVF order",
        );
        my @left = grep { !m/\.ova$/ } glob("$import_dir/* $import_dir/.*[!.]*");
        is_deeply(\@left, [], "export ($format): no staging files left");

        my $x = "$dir/x-$format";
        mkdir $x;
        run_command(['tar', '-xf', $ova, '-C', $x]);
        my $manifest = PVE::Tools::file_get_contents("$x/test-$format.mf");
        my $ok = 1;
        for my $line (split(/\n/, $manifest)) {
            my ($file, $sum) = $line =~ m/^SHA256\((.+)\)= ([0-9a-f]{64})$/ or ($ok = 0, last);
            $ok = 0 if Digest::SHA->new(256)->addfile("$x/$file")->hexdigest() ne $sum;
        }
        ok($ok, "export ($format): manifest checksums");

        for my $test (["ckd0", $ckd, 'raw'], ["fba0", $fba, 'qcow2']) {
            my ($key, $src, $src_format) = @$test;
            my $img = "$x/test-$format-$key.$format";
            my $back = "$x/$key.back.raw";
            my $orig = "$x/$key.orig.raw";
            run_command(['/usr/bin/qemu-img', 'convert', '-f', $format, '-O', 'raw', $img, $back]);
            run_command([
                '/usr/bin/qemu-img', 'convert', '-f', $src_format, '-O', 'raw', $src, $orig,
            ]);
            my $same = eval { run_command(['cmp', $orig, $back]); 1 };
            ok($same, "export ($format): $key content byte for byte");
        }
        my $head = PVE::QemuServer::DASD::read_image_head("$x/test-$format-ckd0.$format", $format);
        my $header = PVE::QemuServer::DASD::parse_ckd_header($head, -s $ckd);
        is($header->{cylinders}, $cylinders, "export ($format): CKD header cylinders");
        is($header->{serial}, '123456789012', "export ($format): CKD serial kept");

        my $ovf = PVE::Tools::file_get_contents("$x/test-$format.ovf");
        my $xpc = xpc_of($ovf);
        is(
            $xpc->findvalue('//ovf:Disk[@ovf:diskId="ckd0"]/@ovf:capacity'),
            -s $ckd,
            "export ($format): CKD capacity in bytes",
        );
    }

    $written_conf->{lock} = 'backup';
    eval { PVE::QemuServer::OVA::export_ova({}, 900, 'local', { filename => 'locked' }) };
    like($@, qr/locked/, 'export of a locked VM refused');
    is($written_conf->{lock}, 'backup', 'lock of a locked VM kept');
    delete $written_conf->{lock};

    $helpers_module->mock(vm_running_locally => sub { 1 });
    eval { PVE::QemuServer::OVA::export_ova({}, 900, 'local', { filename => 'running' }) };
    like($@, qr/is running/, 'export of a running VM refused');

    eval { PVE::QemuServer::OVA::export_ova({}, 900, 'local', { filename => 'test-vmdk' }) };
    like($@, qr/already exists/, 'existing OVA not overwritten');
}

done_testing();
