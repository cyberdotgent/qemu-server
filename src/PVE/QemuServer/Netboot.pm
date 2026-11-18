package PVE::QemuServer::Netboot;

# Network boot of s390x installers. s390x has no CD-ROM boot path for most installers: they are
# loaded as kernel, initial RAM disk and parameter file, which an .ins file lists for the "load from
# removable media or server" function of the HMC. The 'netboot' option points to such an .ins file
# on an HTTP(S) server. Its files are fetched once into the snippets directory of a storage, so a
# start does not depend on the network, and passed to QEMU as -kernel, -initrd and -append.

use strict;
use warnings;

use Digest::SHA;
use File::Basename qw(dirname);
use File::Path;
use LWP::UserAgent;
use URI;

use PVE::Cluster;
use PVE::JSONSchema qw(parse_property_string print_property_string);
use PVE::Storage;
use PVE::Tools;

# Size limits of the fetched files: the list-directed IPL loads everything below 2 GiB.
our $MAX_LIST_SIZE = 64 * 1024;
our $MAX_KERNEL_SIZE = 256 * 1024 * 1024;
our $MAX_INITRD_SIZE = 1024 * 1024 * 1024;
our $MAX_PARMFILE_SIZE = 64 * 1024;
our $MAX_CMDLINE_LENGTH = 4096;

# Addresses in the .ins file: the kernel image is loaded at 0, the parameter file at the kernel
# command line in its parameter area. The rest of that area (0x10400 to 0x10480) holds the start
# and size of the initial RAM disk, which QEMU fills in itself for -initrd.
my $KERNEL_ADDR = 0x0;
my $PARMAREA_START = 0x10400;
my $PARMFILE_ADDR = 0x10480;
my $LIST_LOAD_LIMIT = 0x80000000;

my $netboot_fmt = {
    url => {
        default_key => 1,
        type => 'string',
        pattern => 'https?://[^\s,;]+',
        maxLength => 1024,
        format_description => 'URL',
        description => "The HTTP or HTTPS URL of the .ins file of the installer, which lists its"
            . " kernel, initial RAM disk and parameter file with their load addresses. A z/VM"
            . " reader IPL exec (.exec, PUNCH lines) is also accepted.",
    },
    storage => {
        type => 'string',
        format => 'pve-storage-id',
        optional => 1,
        format_description => 'storage ID',
        description => "Fetch the files listed by the URL into the snippets of this storage."
            . " Only used when the files are fetched, i.e. when 'kernel' is not set.",
    },
    kernel => {
        type => 'string',
        format => 'pve-volume-id',
        optional => 1,
        format_description => 'volume',
        description => "The fetched kernel image (a snippets volume).",
    },
    initrd => {
        type => 'string',
        format => 'pve-volume-id',
        optional => 1,
        format_description => 'volume',
        description => "The fetched initial RAM disk (a snippets volume).",
    },
    once => {
        type => 'boolean',
        optional => 1,
        default => 1,
        description => "Boot the installer only once: starting the VM with it marks this option"
            . " for removal, which happens at the next start. A guest reboot within the same"
            . " start re-IPLs the device the installer has chosen (for example with chreipl).",
    },
};
PVE::JSONSchema::register_format('pve-qm-netboot', $netboot_fmt);

our $netboot_desc = {
    optional => 1,
    type => 'string',
    format => 'pve-qm-netboot',
    description => "Network boot of an s390x installer from an .ins file. Without 'kernel', the"
        . " files are fetched into 'storage' when the option is set. Not used together with"
        . " 'ipl'. The fetched files are named after the URL and shared by all VMs booting the"
        . " same installer, so neither removing the option nor destroying the VM deletes them;"
        . " remove 'netboot-<hash>.kernel/.initrd' from the snippets when no longer needed.",
};

our $netboot_cmdline_desc = {
    optional => 1,
    type => 'string',
    maxLength => $MAX_CMDLINE_LENGTH,
    pattern => '[^\n]*',
    description => "The kernel command line for the network boot. Set from the parameter file"
        . " of the installer when it is fetched, unless given.",
};

sub parse_netboot {
    my ($value) = @_;
    return parse_property_string($netboot_fmt, $value);
}

sub print_netboot {
    my ($netboot) = @_;
    return print_property_string($netboot, $netboot_fmt);
}

# Whether the files of a 'netboot' value still need to be fetched.
sub needs_fetch {
    my ($netboot) = @_;
    return !defined($netboot->{kernel});
}

# Parse the contents of an .ins file. Returns the file names of the kernel, the initial RAM disk
# (optional) and the parameter file (optional), classified by load address, as the order of the
# lines differs between distributions.
sub parse_ins {
    my ($content) = @_;

    my $res = {};
    my $other = [];
    my $line_no = 0;
    for my $line (split(/\n/, $content)) {
        $line_no++;
        $line =~ s/\r$//;
        next if $line =~ m/^\s*(?:\*|$)/;

        my ($file, $addr_text, @rest) = split(' ', $line);
        die ".ins line $line_no: expected a file name and a load address\n"
            if !defined($addr_text) || @rest;
        die ".ins line $line_no: invalid load address '$addr_text'\n"
            if $addr_text !~ m/^(?:0x)?([0-9a-fA-F]{1,8})$/;
        my $addr = hex($1);
        die ".ins line $line_no: load address '$addr_text' is above 2 GiB\n"
            if $addr >= $LIST_LOAD_LIMIT;

        if ($addr == $KERNEL_ADDR) {
            die ".ins line $line_no: second file at address 0\n" if defined($res->{kernel});
            $res->{kernel} = $file;
        } elsif ($addr == $PARMFILE_ADDR) {
            die ".ins line $line_no: second parameter file\n" if defined($res->{parmfile});
            $res->{parmfile} = $file;
        } elsif ($addr >= $PARMAREA_START && $addr < $PARMFILE_ADDR) {
            # initial RAM disk start and size, QEMU sets them for -initrd
        } elsif ($addr < $PARMAREA_START + 0x100) {
            die ".ins line $line_no: unsupported load address '$addr_text'\n";
        } else {
            push @$other, $file;
        }
    }

    die ".ins file lists no kernel (a file loaded at address 0)\n" if !defined($res->{kernel});
    die ".ins file lists more than one initial RAM disk: " . join(', ', @$other) . "\n"
        if scalar(@$other) > 1;
    $res->{initrd} = $other->[0] if @$other;

    return $res;
}

# Parse a z/VM REXX exec that punches the installer to the virtual reader, like Debian's
# debian.exec. The reader deck order is fixed: kernel, parameter file, initial RAM disk. The CMS
# file name and type map to '<name>.<type>' in lower case, next to the exec.
sub parse_exec {
    my ($content) = @_;

    my $files = [];
    for my $line (split(/\n/, $content)) {
        next if $line !~ m/^\s*'\s*PUNCH\s+(\S+)\s+(\S+)\s/i;
        push @$files, lc("$1.$2");
    }
    die "exec does not punch kernel, parameter file and initial RAM disk\n"
        if scalar(@$files) != 3;

    return { kernel => $files->[0], parmfile => $files->[1], initrd => $files->[2] };
}

# The kernel command line from a parameter file: the lines are concatenated with a space.
sub parmfile_to_cmdline {
    my ($content) = @_;

    my $cmdline = join(' ', grep { length } map { s/^\s+|\s+$//gr } split(/\r?\n/, $content));
    die "parameter file contains invalid characters\n" if $cmdline =~ m/[^\x20-\x7e]/;
    die "parameter file is longer than $MAX_CMDLINE_LENGTH characters\n"
        if length($cmdline) > $MAX_CMDLINE_LENGTH;

    return $cmdline;
}

# The URL of a file listed in the .ins or exec, relative to it unless absolute.
sub component_url {
    my ($list_url, $file) = @_;

    my $uri = URI->new_abs($file, $list_url);
    die "unsupported URL '$uri' for '$file', only HTTP and HTTPS are allowed\n"
        if !$uri->scheme || $uri->scheme !~ m/^https?$/;

    return $uri->as_string;
}

# The snippets volume names of the fetched files, derived from the URL, so that VMs installed
# from the same URL share them, and fetching again replaces them.
sub volume_names {
    my ($url) = @_;

    my $hash = substr(Digest::SHA::sha256_hex($url), 0, 12);
    return {
        kernel => "snippets/netboot-$hash.kernel",
        initrd => "snippets/netboot-$hash.initrd",
    };
}

my sub user_agent {
    my ($max_size) = @_;

    my $ua = LWP::UserAgent->new(
        protocols_allowed => ['http', 'https'],
        timeout => 60,
        max_redirect => 5,
        max_size => $max_size,
        ssl_opts => { verify_hostname => 1 },
    );
    $ua->agent("pve-qemu-server");

    my $dccfg = PVE::Cluster::cfs_read_file('datacenter.cfg');
    if (my $proxy = $dccfg->{http_proxy}) {
        $ua->proxy(['http', 'https'], $proxy);
    }

    return $ua;
}

# Fetch a URL, into memory or into $dest (atomically). Dies when the response is larger than
# $max_size.
sub fetch_url {
    my ($url, $max_size, $dest) = @_;

    print "fetching $url\n";

    my $ua = user_agent($max_size);
    my $tmp = defined($dest) ? "$dest.tmp.$$" : undef;
    my $res = eval {
        my $response = defined($tmp) ? $ua->get($url, ':content_file' => $tmp) : $ua->get($url);
        die "fetching '$url' failed: " . $response->status_line . "\n"
            if !$response->is_success;
        if (my $aborted = $response->header('Client-Aborted')) {
            die "fetching '$url' aborted: larger than $max_size bytes\n" if $aborted eq 'max-size';
            die "fetching '$url' aborted: $aborted\n";
        }
        if (my $died = $response->header('X-Died')) {
            die "fetching '$url' failed: $died\n";
        }
        if (defined($tmp)) {
            my $size = -s $tmp;
            die "fetching '$url' failed: empty file\n" if !$size;
            rename($tmp, $dest) or die "unable to rename '$tmp' to '$dest' - $!\n";
            print "saved $size bytes\n";
            return $dest;
        }
        return $response->decoded_content(charset => 'none');
    };
    if (my $err = $@) {
        unlink($tmp) if defined($tmp);
        die $err;
    }

    return $res;
}

# Fetch the files of a 'netboot' value into its storage. Returns the new value, with the volumes
# set and 'storage' removed, and the kernel command line from the parameter file.
sub fetch {
    my ($storecfg, $netboot) = @_;

    my $url = $netboot->{url};
    my $storeid = $netboot->{storage} or die "netboot: 'storage' is required to fetch '$url'\n";
    my $scfg = PVE::Storage::storage_config($storecfg, $storeid);
    die "netboot: storage '$storeid' does not support snippets\n"
        if !$scfg->{content}->{snippets};

    my $list = fetch_url($url, $MAX_LIST_SIZE);
    my $files = $url =~ m/\.exec$/i ? parse_exec($list) : parse_ins($list);

    my $cmdline = '';
    if (defined($files->{parmfile})) {
        my $parmfile_url = component_url($url, $files->{parmfile});
        $cmdline = parmfile_to_cmdline(fetch_url($parmfile_url, $MAX_PARMFILE_SIZE));
    }

    PVE::Storage::activate_storage($storecfg, $storeid);
    my $names = volume_names($url);
    my $res = { url => $url };
    $res->{once} = $netboot->{once} if defined($netboot->{once});
    for my $component (qw(kernel initrd)) {
        next if !defined($files->{$component});
        my $volid = "$storeid:$names->{$component}";
        my $path = PVE::Storage::path($storecfg, $volid);
        File::Path::make_path(dirname($path));
        my $max_size = $component eq 'kernel' ? $MAX_KERNEL_SIZE : $MAX_INITRD_SIZE;
        fetch_url(component_url($url, $files->{$component}), $max_size, $path);
        $res->{$component} = $volid;
    }

    return ($res, $cmdline);
}

# The volumes of a 'netboot' value, for activation and access checks.
sub get_volumes {
    my ($conf) = @_;

    return [] if !$conf->{netboot};
    my $netboot = eval { parse_netboot($conf->{netboot}) } or return [];
    return [grep { defined } $netboot->@{qw(kernel initrd)}];
}

# The QEMU arguments for the network boot of a VM config.
sub get_command_args {
    my ($storecfg, $conf) = @_;

    my $netboot = parse_netboot($conf->{netboot});
    die "netboot: the files of '$netboot->{url}' were not fetched\n" if needs_fetch($netboot);

    my $args = ['-kernel', scalar(PVE::Storage::path($storecfg, $netboot->{kernel}))];
    push @$args, '-initrd', scalar(PVE::Storage::path($storecfg, $netboot->{initrd}))
        if defined($netboot->{initrd});
    push @$args, '-append', $conf->{'netboot-cmdline'}
        if length($conf->{'netboot-cmdline'} // '');

    return $args;
}

# Whether the network boot is removed after a start that used it.
sub is_once {
    my ($conf) = @_;

    my $netboot = eval { parse_netboot($conf->{netboot}) } or return 0;
    return $netboot->{once} // 1;
}

1;
