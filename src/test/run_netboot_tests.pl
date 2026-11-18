#!/usr/bin/perl

use v5.36;

use lib qw(..);

use File::Temp qw(tempdir);
use Test::MockModule;
use Test::More;

use PVE::File qw(file_get_contents file_set_contents);
use PVE::QemuServer::Netboot;

# .ins files as the distributions ship them
my $ins_tests = [
    [
        'Debian ISO d390.ins',
        "* Debian GNU/Linux for S/390 (boot from CD-ROM or FTP-Server)\n"
            . "boot/linux_vm 0x00000000\n"
            . "boot/root.off 0x0001040c\n"
            . "boot/root.siz 0x00010414\n"
            . "boot/parmfile 0x00010480\n"
            . "boot/root.bin 0x01000000\n",
        { kernel => 'boot/linux_vm', parmfile => 'boot/parmfile', initrd => 'boot/root.bin' },
    ],
    [
        'RHEL/Fedora generic.ins',
        "* minimal lpar ins file\r\n"
            . "images/kernel.img 0x00000000\r\n"
            . "images/initrd.img 0x02000000\r\n"
            . "images/genericdvd.prm 0x00010480\r\n"
            . "images/initrd.addrsize 0x00010408\r\n",
        {
            kernel => 'images/kernel.img',
            parmfile => 'images/genericdvd.prm',
            initrd => 'images/initrd.img',
        },
    ],
    [
        'SUSE suse.ins (initrd before the parameter file)',
        "* SUSE Linux for IBM z Systems Installation/Rescue System\n"
            . "boot/s390x/linux 0x00000000\n"
            . "boot/s390x/initrd.off 0x0001040c\n"
            . "boot/s390x/initrd.siz 0x00010414\n"
            . "boot/s390x/initrd 0x01000000\n"
            . "boot/s390x/parmfile 0x00010480\n",
        {
            kernel => 'boot/s390x/linux',
            parmfile => 'boot/s390x/parmfile',
            initrd => 'boot/s390x/initrd',
        },
    ],
    [
        'kernel only, tabs and addresses without 0x',
        "\n  *comment\nkernel\t00000000\n",
        { kernel => 'kernel' },
    ],
    ['no kernel', "initrd 0x01000000\n", undef, qr/lists no kernel/],
    ['two kernels', "a 0x0\nb 0x00000000\n", undef, qr/second file at address 0/],
    ['two initrds', "k 0x0\na 0x01000000\nb 0x02000000\n", undef, qr/more than one initial/],
    ['missing address', "kernel\n", undef, qr/line 1: expected a file name/],
    ['extra field', "kernel 0x0 x\n", undef, qr/line 1: expected a file name/],
    ['invalid address', "kernel 0xg0\n", undef, qr/invalid load address/],
    ['address above 2 GiB', "k 0x0\ninitrd 0x80000000\n", undef, qr/above 2 GiB/],
    ['address in the low core', "k 0x0\nx 0x00001000\n", undef, qr/unsupported load address/],
];

for my $test ($ins_tests->@*) {
    my ($name, $content, $expected, $error) = $test->@*;
    my $res = eval { PVE::QemuServer::Netboot::parse_ins($content) };
    if ($expected) {
        is_deeply($res, $expected, "parse_ins: $name");
        diag($@) if $@;
    } else {
        like($@, $error, "parse_ins: $name is refused");
    }
}

my $debian_exec = <<'EOF';
/* REXX EXEC TO IPL DEBIAN GNU/LINUX  */
/* FOR S/390 FROM THE VM READER.      */
/*                                    */
'CP CLOSE RDR'
'PURGE RDR ALL'
'SPOOL PUNCH * RDR'
'PUNCH KERNEL    DEBIAN   * (NOHEADER'
'PUNCH PARMFILE  DEBIAN   * (NOHEADER'
'PUNCH INITRD    DEBIAN   * (NOHEADER'
'CHANGE RDR ALL KEEP NOHOLD'
'CP IPL 000C CLEAR'
EOF
is_deeply(
    PVE::QemuServer::Netboot::parse_exec($debian_exec),
    { kernel => 'kernel.debian', parmfile => 'parmfile.debian', initrd => 'initrd.debian' },
    'parse_exec: Debian debian.exec',
);
eval { PVE::QemuServer::Netboot::parse_exec("'CP IPL 000C CLEAR'\n") };
like($@, qr/does not punch/, 'parse_exec: exec without PUNCH lines is refused');

is(
    PVE::QemuServer::Netboot::parmfile_to_cmdline("ro locale=C\n"),
    'ro locale=C',
    'parmfile: one line',
);
is(
    PVE::QemuServer::Netboot::parmfile_to_cmdline(
        "ro ramdisk_size=40000 cio_ignore=all,!condev\r\n  rd.cmdline=ask \n\n"),
    'ro ramdisk_size=40000 cio_ignore=all,!condev rd.cmdline=ask',
    'parmfile: lines are joined with a space',
);
eval { PVE::QemuServer::Netboot::parmfile_to_cmdline("ro\x00x") };
like($@, qr/invalid characters/, 'parmfile: binary content is refused');
eval { PVE::QemuServer::Netboot::parmfile_to_cmdline('x' x 4097) };
like($@, qr/longer than 4096/, 'parmfile: too long is refused');

my $url_tests = [
    ['https://example.com/s390x/os/generic.ins', 'images/kernel.img',
        'https://example.com/s390x/os/images/kernel.img'],
    ['http://example.com/a/b/suse.ins', '../c/linux', 'http://example.com/a/c/linux'],
    ['https://example.com/a/ubuntu.ins', 'https://other.example.com/k', 'https://other.example.com/k'],
];
for my $test ($url_tests->@*) {
    my ($base, $file, $expected) = $test->@*;
    is(PVE::QemuServer::Netboot::component_url($base, $file), $expected, "component URL of $file");
}
for my $file ('file:///etc/shadow', 'ftp://example.com/kernel') {
    eval { PVE::QemuServer::Netboot::component_url('https://example.com/x.ins', $file) };
    like($@, qr/only HTTP and HTTPS/, "component URL $file is refused");
}

for my $value (
    'https://example.com/generic.ins',
    'url=http://example.com/generic.ins,storage=local,once=0',
    'https://example.com/generic.ins,kernel=local:snippets/netboot-0123456789ab.kernel',
) {
    ok(eval { PVE::QemuServer::Netboot::parse_netboot($value) }, "netboot '$value' is valid");
}
for my $value ('ftp://example.com/generic.ins', 'file:///generic.ins', 'storage=local') {
    ok(!eval { PVE::QemuServer::Netboot::parse_netboot($value) }, "netboot '$value' is invalid");
}

# fetching, with the HTTP server and storage mocked
my $dir = tempdir(CLEANUP => 1);
my $server = {
    'https://example.com/os/generic.ins' => "images/kernel.img 0x0\nimages/initrd.img 0x02000000\n"
        . "images/generic.prm 0x00010480\nimages/initrd.addrsize 0x00010408\n",
    'https://example.com/os/images/kernel.img' => 'KERNEL',
    'https://example.com/os/images/initrd.img' => 'INITRD',
    'https://example.com/os/images/generic.prm' => "ro\ninst.repo=https://example.com/os\n",
};
my $fetched = [];
my $netboot_module = Test::MockModule->new('PVE::QemuServer::Netboot');
$netboot_module->mock(
    fetch_url => sub {
        my ($url, $max_size, $dest) = @_;
        push @$fetched, $url;
        my $content = $server->{$url} // die "404 $url\n";
        die "too large\n" if length($content) > $max_size;
        return $content if !defined($dest);
        file_set_contents($dest, $content);
        return $dest;
    },
);
my $storage_module = Test::MockModule->new('PVE::Storage');
$storage_module->mock(
    storage_config => sub {
        my ($cfg, $storeid) = @_;
        return { content => { snippets => $storeid eq 'local' ? 1 : 0, iso => 1 } };
    },
    activate_storage => sub { },
    path => sub {
        my ($cfg, $volid) = @_;
        my (undef, $name) = $volid =~ m/^([^:]+):snippets\/(.+)$/ or die "bad $volid\n";
        return "$dir/snippets/$name";
    },
);

my ($netboot, $cmdline) = PVE::QemuServer::Netboot::fetch(
    {}, { url => 'https://example.com/os/generic.ins', storage => 'local', once => 0 },
);
my $names = PVE::QemuServer::Netboot::volume_names('https://example.com/os/generic.ins');
is_deeply(
    $netboot,
    {
        url => 'https://example.com/os/generic.ins',
        kernel => "local:$names->{kernel}",
        initrd => "local:$names->{initrd}",
        once => 0,
    },
    'fetch: volumes set, storage dropped',
);
is($cmdline, 'ro inst.repo=https://example.com/os', 'fetch: command line from the parameter file');
is_deeply(
    $fetched,
    [map { "https://example.com/os/$_" }
        qw(generic.ins images/generic.prm images/kernel.img images/initrd.img)],
    'fetch: only the listed files are fetched',
);
is(file_get_contents("$dir/$names->{kernel}"), 'KERNEL', 'fetch: kernel stored');
like($names->{kernel}, qr/^snippets\/netboot-[0-9a-f]{12}\.kernel$/, 'fetch: volume name');

eval {
    PVE::QemuServer::Netboot::fetch({}, { url => 'https://example.com/os/generic.ins', storage => 'nfs' });
};
like($@, qr/does not support snippets/, 'fetch: storage without snippets is refused');

eval { PVE::QemuServer::Netboot::fetch({}, { url => 'https://example.com/os/generic.ins' }) };
like($@, qr/'storage' is required/, 'fetch: storage is required');

my $conf = {
    netboot => "url=https://example.com/os/generic.ins,kernel=local:$names->{kernel}"
        . ",initrd=local:$names->{initrd}",
    'netboot-cmdline' => 'ro quiet',
};
is_deeply(
    PVE::QemuServer::Netboot::get_command_args({}, $conf),
    [
        '-kernel', "$dir/$names->{kernel}",
        '-initrd', "$dir/$names->{initrd}",
        '-append', 'ro quiet',
    ],
    'command line arguments',
);
is_deeply(
    PVE::QemuServer::Netboot::get_volumes($conf),
    ["local:$names->{kernel}", "local:$names->{initrd}"],
    'volumes of the network boot',
);
ok(PVE::QemuServer::Netboot::is_once($conf), 'boots once by default');
ok(!PVE::QemuServer::Netboot::is_once({ netboot => "$conf->{netboot},once=0" }), 'once=0');

done_testing();
