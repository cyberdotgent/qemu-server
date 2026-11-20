#!/usr/bin/perl

# The storage for the state of a hibernated VM or a RAM snapshot: one with content
# type 'images', from which the VM can be started again.

use v5.36;

use lib qw(..);

use Test::MockModule;
use Test::More;

use PVE::QemuConfig;

my $storecfg = {
    ids => {
        local => { type => 'dir', path => '/var/lib/vz', content => { iso => 1, import => 1 } },
        'local-zfs' => { type => 'zfspool', content => { images => 1, rootdir => 1 } },
        'local-zfs-dir' => { type => 'dir', path => '/rpool/dir', content => { images => 1 } },
        nfs => { type => 'nfs', path => '/mnt/pve/nfs', shared => 1, content => { images => 1 } },
        off => { type => 'dir', path => '/off', disable => 1, content => { images => 1 } },
    },
};

my $storage = Test::MockModule->new('PVE::Storage');
$storage->mock(
    storage_check_node => sub {
        my ($cfg, $storeid) = @_;
        return $cfg->{ids}->{$storeid};
    },
);

my $find = sub {
    my ($conf, $cfg) = @_;
    return eval { PVE::QemuConfig::find_vmstate_storage($conf, $cfg // $storecfg) } // $@;
};

is($find->({ vmstatestorage => 'nfs' }), 'nfs', 'configured storage');
is($find->({ scsi0 => 'local-zfs:vm-100-disk-0' }), 'local-zfs', 'storage of a disk');
is(
    $find->({ scsi0 => 'local-zfs:vm-100-disk-0', scsi1 => 'local-zfs-dir:100/vm-100-disk-0.raw' }),
    'local-zfs-dir',
    'file based storage of a disk preferred',
);
is(
    $find->({ scsi0 => 'local-zfs:vm-100-disk-0', scsi1 => 'nfs:100/vm-100-disk-0.raw' }),
    'nfs',
    'shared storage of a disk preferred',
);
is(
    $find->({ ide2 => 'local:iso/install.iso,media=cdrom' }),
    'local-zfs-dir',
    'no disk, ISO on a storage without images, local without images: first file based storage',
);
is($find->({}), 'local-zfs-dir', 'no disk: first file based storage with images');

my $with_local = {
    ids => { $storecfg->{ids}->%*, local => { type => 'dir', path => '/var/lib/vz', content => { images => 1 } } },
};
is($find->({}, $with_local), 'local', 'no disk: local, if it has images');

my $only_block = { ids => { 'local-zfs' => $storecfg->{ids}->{'local-zfs'} } };
is($find->({}, $only_block), 'local-zfs', 'no disk: any storage with images');

my $none = { ids => { local => $storecfg->{ids}->{local}, off => $storecfg->{ids}->{off} } };
like($find->({}, $none), qr/no storage for the VM state/, 'no storage with images: refused');

done_testing();
